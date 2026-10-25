#!/usr/bin/env magix
#!magix haskell
#!haskellPackages mustache pandoc shake feed yaml
#!ghcFlags -threaded -O2
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall -Wno-x-partial #-}

-- | The build graph is in 'buildTargets' (what to produce) and 'buildRules'
-- (how to produce it); new page types can follow one of the existing groups.
module Main where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans (lift)
import Data.Aeson (FromJSON, ToJSON, (.=))
import Data.Aeson.Types qualified as A
import Data.Function (on)
import Data.Functor ((<&>))
import Data.HashMap.Strict qualified as HM
import Data.List (find, nub, nubBy, sortOn, (\\))
import Data.Maybe (fromMaybe)
import Data.Ord qualified as Ord
import Data.Text qualified as T
import Data.Text.IO.Utf8 qualified as TU
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Data.Yaml qualified as Yaml
import Development.Shake (Action, Rules, (%>), (&%>), (|%>), (~>))
import Development.Shake qualified as Shake
import Development.Shake.FilePath ((<.>), (</>))
import Development.Shake.FilePath qualified as Shake
import Development.Shake.Util qualified as Shake (shakeArgsPrune)
import System.Directory (doesDirectoryExist, removeFile)
import Text.Atom.Feed qualified as Atom
import Text.Atom.Feed.Export qualified as Atom
import Text.Mustache qualified as Mus
import Text.Mustache.Compile qualified as Mus
import Text.Pandoc (Block (Plain), Inline (..), Meta (..), MetaValue (..), Pandoc (..))
import Text.Pandoc qualified as Pandoc
import Text.Pandoc.Walk qualified as Pandoc
import Prelude hiding (readFile, writeFile)

main :: IO ()
main = do
  config <- Yaml.decodeFileThrow "config.yaml"
  -- The feed and templates assume there is a first author.
  when (null config.authors) $ do
    error "There should be at least one author"

  templateCache <- newTemplateCache
  postCache <- newPostCache config
  let ctx = Context config templateCache postCache

  Shake.shakeArgsPrune Shake.shakeOptions pruneStaleFiles $ do
    Shake.withTargetDocs "Build the site" $
      "build" ~> runRAction ctx buildTargets
    Shake.withTargetDocs "Clean the built site" $
      "clean" ~> Shake.removeFilesAfter outputDir ["//*"]

    -- These rules are hidden from the command-line target list (and --help),
    -- but are still used internally when the build target needs their outputs.
    Shake.withoutTargets $ runRRules ctx buildRules

-- Settings
--
-- Paths are relative to the project root, where @./blog.hs@ is run.

outputDir :: FilePath
outputDir = "_site"

assetGlobs :: [Shake.FilePattern]
assetGlobs = ["css/*.css", "images/*.png", "images/*.svg", "images/*.jpg"]

pagePaths :: [FilePath]
pagePaths = ["contact.md"]

postGlobs :: [Shake.FilePattern]
postGlobs = ["posts/*.md"]

archivePath :: FilePath
archivePath = "archive"

tagArchivePath :: FilePath
tagArchivePath = "tags"

homePostCount :: Int
homePostCount = 5

feedFileName :: String
feedFileName = "feed.atom"

-- Config
--
-- These types are both parsed from @config.yaml@ ('FromJSON') and exposed to
-- templates as the @site@ value ('ToJSON').

data AuthorConfig = AuthorConfig
  { name :: T.Text,
    uri :: T.Text,
    email :: T.Text,
    copyrightYear :: T.Text
  }
  deriving (Show)

data SiteConfig = SiteConfig
  { title :: T.Text,
    -- | Absolute URL, without a trailing slash.
    url :: T.Text,
    description :: T.Text,
    -- | At least one is required.
    authors :: [AuthorConfig]
  }
  deriving (Show)

instance ToJSON AuthorConfig where
  toJSON AuthorConfig {..} =
    A.object
      [ "name" .= name,
        "uri" .= uri,
        "email" .= email,
        "copyright_year" .= copyrightYear
      ]

instance ToJSON SiteConfig where
  toJSON SiteConfig {..} =
    A.object
      [ "title" .= title,
        "url" .= url,
        "description" .= description,
        -- This is a convenience alias for templates; all authors are also in
        -- "authors".
        "author" .= head authors,
        "authors" .= authors
      ]

instance FromJSON AuthorConfig where
  parseJSON = A.withObject "AuthorConfig" $ \o ->
    AuthorConfig
      <$> o A..: "name"
      <*> o A..: "uri"
      <*> o A..: "email"
      <*> o A..: "copyright_year"

instance FromJSON SiteConfig where
  parseJSON = A.withObject "SiteConfig" $ \o ->
    SiteConfig
      <$> o A..: "title"
      <*> o A..: "url"
      <*> o A..: "description"
      <*> o A..: "authors"

-- Shake
--
-- Shake selects a rule by the output path it builds, so config and caches
-- cannot be passed as rule arguments. They travel in this Reader instead.

-- | Several rules need the same post, so each file is parsed once per run.
type PostCache = FilePath -> Action Post

-- | Compiled templates are cached per run, including their partials.
type TemplateCache = FilePath -> Action Mus.Template

data Context = Context
  { config :: SiteConfig,
    templateCache :: TemplateCache,
    postCache :: PostCache
  }

class (MonadIO m, MonadFail m) => MonadAction m where
  liftAction :: Action a -> m a

instance MonadAction Action where
  liftAction = id

type RAction = ReaderT Context Action

type RRules = ReaderT Context Rules

instance MonadAction RAction where
  liftAction = lift

runRAction :: Context -> RAction a -> Action a
runRAction = flip runReaderT

runRRules :: Context -> RRules a -> Rules a
runRRules = flip runReaderT

-- Build

-- | Builds the complete site.
buildTargets :: RAction ()
buildTargets = do
  assetPaths <- getDirFiles assetGlobs
  postPaths <- getDirFiles postGlobs

  -- Add outputs for any new page type here.
  need assetPaths
  need $ map indexHtmlOutputPath pagePaths
  need $ map indexHtmlOutputPath postPaths
  need [feedFileName, archivePath </> "index.html", "index.html"]

  -- Tags are only known after reading the posts, so this comes last.
  ctx <- ask
  posts <- forP postPaths $ getPost ctx.postCache
  need [indexHtmlOutputPath $ tagArchivePath </> T.unpack tag | post <- posts, tag <- post.tags]

-- | Registers all rule groups.
buildRules :: RRules ()
buildRules = do
  -- Order is irrelevant: Shake matches rule groups by output pattern.
  assetRules
  pageRules
  postRules
  postFeedRules
  archiveRules
  tagArchiveRules
  homeRules

-- Assets

-- | Copies static assets into the output directory.
assetRules :: RRules ()
assetRules =
  -- New asset types only need an entry in assetGlobs.
  assetGlobs |@> \target -> do
    let src = Shake.dropDirectory1 target
    copyFileChanged src target
    putInfo $ "Copied " <> target <> " from " <> src

-- Pages

data Page = Page
  { title :: T.Text,
    mainClass :: T.Text,
    baseUrl :: T.Text,
    content :: T.Text,
    config :: SiteConfig
  }
  deriving (Show)

instance ToJSON Page where
  toJSON Page {..} =
    A.object
      [ "title" .= title,
        "main_class" .= mainClass,
        "base_url" .= baseUrl,
        "content" .= content,
        "site" .= config
      ]

getBaseUrl :: (MonadAction m) => SiteConfig -> m T.Text
getBaseUrl config =
  liftAction (Shake.getEnvWithDefault "DEV" "ENV")
    <&> \case
      "PROD" -> config.url
      _ -> ""

mkPage :: T.Text -> T.Text -> T.Text -> RAction Page
mkPage title mainClass content = do
  ctx <- ask
  baseUrl <- getBaseUrl ctx.config
  pure $ Page {config = ctx.config, ..}

-- | Renders the standalone pages listed in 'pagePaths'.
pageRules :: RRules ()
pageRules =
  map indexHtmlOutputPath pagePaths |@> \target -> do
    let src = indexHtmlSourcePath target
    ctx <- ask
    baseUrl <- getBaseUrl ctx.config
    (meta, html) <- markdownToHtml baseUrl src

    -- Pages have no date, tags, or author; only the front-matter title is used.
    mkPage (meta HM.! ("title" :: T.Text)) "page" html
      >>= applyTemplateAndWrite "default.html" target
    putInfo $ "Built " <> target <> " from " <> src

-- Posts

-- | A post's YAML front matter; @author@ and @tags@ are optional.
data PostMeta = PostMeta
  { title :: T.Text,
    author :: Maybe T.Text,
    tags :: [T.Text]
  }
  deriving (Show)

instance FromJSON PostMeta where
  parseJSON = A.withObject "PostMeta" $ \o ->
    PostMeta
      <$> o A..: "title"
      <*> o A..:? "author"
      <*> o A..:? "tags" A..!= []

instance ToJSON PostMeta where
  toJSON PostMeta {..} =
    A.object
      [ "title" .= title,
        "author" .= author,
        "tags" .= tags
      ]

-- | A rendered post with metadata derived from its filename and config.
data Post = Post
  { title :: T.Text,
    author :: Maybe T.Text,
    tags :: [T.Text],
    date :: T.Text,
    dateTime :: UTCTime,
    content :: T.Text,
    -- | Absolute in PROD, root-relative in DEV.
    url :: T.Text,
    baseUrl :: T.Text,
    config :: SiteConfig
  }
  deriving (Show)

instance ToJSON Post where
  toJSON Post {..} =
    A.object
      [ "title" .= title,
        "author" .= author,
        "tags" .= tags,
        "date" .= date,
        "date_time" .= dateTime,
        "content" .= content,
        "url" .= url,
        "base_url" .= baseUrl,
        "site" .= config
      ]

-- | Reads and renders one post.
readPost :: (MonadAction m) => SiteConfig -> FilePath -> m Post
readPost config postPath = do
  -- The date is the first ten filename characters, so month and day must be
  -- zero-padded.
  dateTime <-
    parseTimeM False defaultTimeLocale "%Y-%-m-%-d"
      . take 10
      . Shake.takeBaseName
      $ postPath
  let date = T.pack $ formatTime @UTCTime defaultTimeLocale "%B %e, %Y" dateTime

  baseUrl <- getBaseUrl config
  (PostMeta {..}, content) <- markdownToHtml baseUrl postPath
  putInfo $ "Read " <> postPath

  return $
    Post
      { url = baseUrl <> "/" <> T.pack (Shake.dropExtension postPath) <> "/",
        ..
      }

newPostCache :: SiteConfig -> IO PostCache
newPostCache = Shake.newCacheIO . readPost

getPost :: (MonadAction m) => PostCache -> FilePath -> m Post
getPost postCache = liftAction . postCache

-- | Returns all posts sorted by display date, descending.
getPosts :: RAction [Post]
getPosts = do
  ctx <- ask
  postPaths <- getDirFiles postGlobs
  -- Use dateTime here for exact chronological order across months.
  sortOn (Ord.Down . date) <$> traverse (getPost ctx.postCache) postPaths

postRules :: RRules ()
postRules =
  map indexHtmlOutputPath postGlobs |@> \target -> do
    ctx <- ask
    let src = indexHtmlSourcePath target
    post <- getPost ctx.postCache src
    postHtml <- applyTemplate "post.html" post

    mkPage post.title "post" postHtml
      >>= applyTemplateAndWrite "default.html" target
    putInfo $ "Built " <> target <> " from " <> src

-- | Writes the Atom feed.
postFeedRules :: RRules ()
postFeedRules =
  feedFileName @> \target -> do
    ctx <- ask
    -- Feed entries need absolute URLs, so use config.url even in DEV.
    getPosts
      >>= traverse mkPostEntry
      >>= writeFeed
        (ctx.config.url <> "/" <> T.pack feedFileName)
        ctx.config.url
        ctx.config.title
        target

archiveRules :: RRules ()
archiveRules =
  (archivePath </> "index.html") @> \target ->
    getPosts >>= writeArchive (T.pack "Archive") Nothing target

-- | Writes an archive page with the given title and posts.
writeArchive :: T.Text -> Maybe T.Text -> FilePath -> [Post] -> RAction ()
writeArchive title tag target posts = do
  ctx <- ask
  baseUrl <- getBaseUrl ctx.config
  html <-
    applyTemplate "archive.html" $
      A.object
        [ "title" .= title,
          "posts" .= posts,
          "tag_path" .= (tag <&> \t -> tagArchivePath <> "/" <> T.unpack t),
          "base_url" .= baseUrl,
          "site" .= ctx.config
        ]
  mkPage title "archive" html >>= applyTemplateAndWrite "default.html" target
  putInfo $ "Built " <> target

-- | Writes one archive page per tag.
tagArchiveRules :: RRules ()
tagArchiveRules =
  (tagArchivePath </> "*/index.html") @> \target -> do
    -- The tag is the path segment after tags/.
    let tag = T.pack $ Shake.splitDirectories target !! 2
    getPosts
      <&> filter (\post -> tag `elem` post.tags)
      >>= writeArchive (T.pack "Posts tagged “" <> tag <> T.pack "”") Nothing target

homeRules :: RRules ()
homeRules =
  "index.html" @> \target -> do
    ctx <- ask
    posts <- take homePostCount <$> getPosts
    baseUrl <- getBaseUrl ctx.config
    html <-
      applyTemplate "home.html" $
        A.object
          [ "posts" .= posts,
            "base_url" .= baseUrl,
            "site" .= ctx.config
          ]

    mkPage "Home" "home" html >>= applyTemplateAndWrite "default.html" target
    putInfo $ "Built " <> target

-- Shake utils

-- | Prefixes an output-relative path with 'outputDir'.
prependOutputDir :: FilePath -> FilePath
prependOutputDir = (outputDir </>)

need :: (MonadAction m) => [FilePath] -> m ()
need = liftAction . Shake.need . map prependOutputDir

putInfo :: (MonadAction m) => String -> m ()
putInfo = liftAction . Shake.putInfo

copyFileChanged :: (MonadAction m) => FilePath -> FilePath -> m ()
copyFileChanged src dst = liftAction $ Shake.copyFileChanged src dst

-- | Finds source files matching the globs. Returned paths are relative to the
-- project root, not 'outputDir'.
getDirFiles :: (MonadAction m) => [Shake.FilePattern] -> m [FilePath]
getDirFiles = liftAction . Shake.getDirectoryFiles ""

forP :: (MonadAction m) => [a] -> (a -> Action b) -> m [b]
forP xs = liftAction . Shake.forP xs

-- | Registers a handler for outputs matching all of the patterns.
(&@>) :: [Shake.FilePattern] -> ([FilePath] -> RAction ()) -> RRules ()
filePatterns &@> f = do
  ctx <- ask
  lift $
    -- Shake passes handlers the target path, including outputDir.
    map prependOutputDir filePatterns &%> \targets ->
      -- Every output depends on the script and config, so editing either
      -- rebuilds the site.
      Shake.need ["blog.hs", "config.yaml"] >> runRAction ctx (f targets)

-- | Registers a handler for output matching any of the patterns.
(|@>) :: [Shake.FilePattern] -> (FilePath -> RAction ()) -> RRules ()
filePatterns |@> f = do
  ctx <- ask
  lift $
    map prependOutputDir filePatterns |%> \target ->
      Shake.need ["blog.hs", "config.yaml"] >> runRAction ctx (f target)

-- | Registers a handler for one output pattern.
(@>) :: Shake.FilePattern -> (FilePath -> RAction ()) -> RRules ()
fp @> f = do
  ctx <- ask
  lift $
    prependOutputDir fp %> \target ->
      Shake.need ["blog.hs", "config.yaml"] >> runRAction ctx (f target)

-- | Maps a source path to its clean-URL output path.
indexHtmlOutputPath :: FilePath -> FilePath
indexHtmlOutputPath srcPath = Shake.dropExtension srcPath </> "index.html"

-- | Maps a clean-URL output path back to its source path.
indexHtmlSourcePath :: FilePath -> FilePath
indexHtmlSourcePath =
  Shake.dropDirectory1
    . (<.> "md")
    . Shake.dropTrailingPathSeparator
    . Shake.dropFileName

feedFileOutputPath :: FilePath -> FilePath
feedFileOutputPath srcPath = Shake.dropExtension srcPath </> feedFileName

-- | Reads a UTF-8 file as a build input.
readFile :: FilePath -> Action T.Text
readFile fp = do
  Shake.need [fp]
  content <- Shake.liftIO $ TU.readFile fp
  -- Recording the read makes dependents rebuild when the file changes.
  Shake.trackRead [fp]
  return content

-- | Writes a UTF-8 file as a build output.
writeFile :: FilePath -> T.Text -> Action ()
writeFile fp content = do
  Shake.liftIO $ TU.writeFile fp content
  -- Recording the write lets Shake track outputs for incremental builds and
  -- pruning.
  Shake.trackWrite [fp]

-- | Prune callback for 'Shake.shakeArgsPrune': removes outputs that this build
-- did not produce.
pruneStaleFiles :: [FilePath] -> IO ()
pruneStaleFiles live = do
  exists <- doesDirectoryExist outputDir
  present <-
    if exists
      then map prependOutputDir <$> Shake.getDirectoryFilesIO outputDir ["//*"]
      else pure []
  let stale = filter (`notElem` keep) $ present \\ live
  unless (null stale) $ do
    putStrLn $ "Pruning " <> show (length stale) <> " stale file(s):"
    mapM_ pruneFile stale
  where
    -- The workflow copies CNAME and adds .nojekyll to _site after the build, so they
    -- may be present in _site even though Shake does not track them.
    keep = map prependOutputDir ["CNAME", ".nojekyll"]

    pruneFile f = do
      putStrLn ("  " <> f)
      result <- try (removeFile f) :: IO (Either IOException ())
      case result of
        Left err -> putStrLn ("  warning: could not remove " <> f <> ": " <> show err)
        Right () -> pure ()

-- Pandoc utils

-- | Decodes the YAML front matter into @a@ and renders the body, rewriting
-- site-root-relative links and images with 'baseUrl'.
markdownToHtml :: (MonadAction m, FromJSON a) => T.Text -> FilePath -> m (a, T.Text)
markdownToHtml baseUrl filePath = liftAction $ do
  content <- readFile filePath
  Shake.quietly . Shake.traced "Markdown to HTML" $ do
    pandoc@(Pandoc meta _) <- runPandoc $ Pandoc.readMarkdown readerOptions content
    let pandoc' = rewriteLinks pandoc
    html <- runPandoc . Pandoc.writeHtml5String writerOptions $ pandoc'
    meta' <- fromMeta meta
    return (meta', html)
  where
    -- Additional Markdown extensions can be enabled here.
    readerOptions =
      Pandoc.def {Pandoc.readerExtensions = Pandoc.pandocExtensions}
    writerOptions =
      Pandoc.def {Pandoc.writerExtensions = Pandoc.pandocExtensions}

    -- Pandoc's Meta has no FromJSON instance, so the value goes through Aeson.
    fromMeta (Meta meta) =
      A.fromJSON . A.toJSON <$> traverse metaValueToJSON meta >>= \case
        A.Success res -> pure res
        A.Error err -> fail $ "json conversion error:" <> err

    metaValueToJSON = \case
      MetaMap m -> A.toJSON <$> traverse metaValueToJSON m
      MetaList m -> A.toJSONList <$> traverse metaValueToJSON m
      MetaBool m -> pure $ A.toJSON m
      MetaString m -> pure $ A.toJSON $ T.strip m
      MetaInlines m -> metaValueToJSON $ MetaBlocks [Plain m]
      MetaBlocks m ->
        fmap (A.toJSON . T.strip)
          . runPandoc
          . Pandoc.writePlain Pandoc.def
          $ Pandoc mempty m

    -- This runs Pandoc's pure pipeline in IO and turns its errors into build
    -- failures.
    runPandoc action =
      Pandoc.runIO (Pandoc.setVerbosity Pandoc.ERROR >> action)
        >>= either (fail . show) return

    -- Only site-root-relative URLs are rewritten; relative and external URLs
    -- are left alone.
    rewriteLinks = Pandoc.walk $ \case
      Link attr inlines (url, title) ->
        Link attr inlines (prependBaseUrl url, title)
      Image attr inlines (url, title) ->
        Image attr inlines (prependBaseUrl url, title)
      other -> other

    prependBaseUrl url
      | T.null baseUrl = url
      | "/" `T.isPrefixOf` url = baseUrl <> url
      | otherwise = url

-- Mustache utils

-- | Applies a template to a context. Fails on missing variables or
-- partials instead of rendering blanks.
applyTemplate :: (ToJSON a) => String -> a -> RAction T.Text
applyTemplate templateName context = do
  ctx <- ask
  tmpl <- lift $ ctx.templateCache $ "templates" </> templateName
  case Mus.checkedSubstitute tmpl (A.toJSON context) of
    ([], text) -> return text
    (errs, _) ->
      fail $ "Error while substituting template " <> templateName <> ": " <> unlines (map show errs)

applyTemplateAndWrite :: (ToJSON a) => String -> FilePath -> a -> RAction ()
applyTemplateAndWrite templateName outputPath context =
  applyTemplate templateName context >>= lift . writeFile outputPath

-- | Compiles a Mustache template and tracks its partials as dependencies.
readTemplate :: FilePath -> Action Mus.Template
readTemplate templatePath = do
  Shake.need [templatePath]
  eTemplate <-
    Shake.quietly
      . Shake.traced "Compile template"
      $ Mus.localAutomaticCompile templatePath
  case eTemplate of
    Right template -> do
      -- Tracking partials makes pages rebuild when a partial changes.
      Shake.need . Mus.getPartials . Mus.ast $ template
      Shake.putInfo $ "Read " <> templatePath
      return template
    Left err -> fail $ show err

newTemplateCache :: IO TemplateCache
newTemplateCache = Shake.newCacheIO readTemplate

-- Feed utils

feedAuthor :: AuthorConfig -> Atom.Person
feedAuthor AuthorConfig {..} =
  Atom.Person
    { personName = name,
      personURI = Just uri,
      personEmail = Just email,
      personOther = []
    }

-- | Converts a post to an Atom feed entry.
mkPostEntry :: Post -> RAction Atom.Entry
mkPostEntry post@Post {..} = do
  let siteUrl = post.config.url
      authors = post.config.authors
      -- post.url is relative in DEV, so make it absolute for the feed.
      entryUrl = if siteUrl `T.isPrefixOf` post.url then post.url else siteUrl <> post.url
      entryUpdated = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" post.dateTime
      -- A post's author names one of the configured profiles; a missing or
      -- unknown name falls back to the first author.
      entryAuthor = fromMaybe (head authors) $ author >>= \n -> find ((== n) . name) authors
  return $
    Atom.Entry
      { entryId = entryUrl,
        entryTitle = Atom.TextString title,
        entryUpdated = entryUpdated,
        entryAuthors = [feedAuthor entryAuthor],
        entryCategories = map (Atom.newCategory . T.strip) tags,
        entryContent = Just $ Atom.HTMLContent post.content,
        entryContributor = [],
        entryLinks = [(Atom.nullLink entryUrl) {Atom.linkRel = Just $ Left "alternate"}],
        entryPublished = Just entryUpdated,
        entryRights = Just $ Atom.TextString $ "© " <> entryAuthor.copyrightYear <> ", " <> entryAuthor.name,
        entrySource = Nothing,
        entrySummary = Nothing,
        entryInReplyTo = Nothing,
        entryInReplyTotal = Nothing,
        entryAttrs = [],
        entryOther = []
      }

-- | Builds an Atom feed from its entries.
mkFeed :: Atom.URI -> Atom.URI -> T.Text -> SiteConfig -> [Atom.Entry] -> Atom.Feed
mkFeed feedUrl feedHtmlUrl title config entries =
  let author = head config.authors
   in Atom.Feed
        { feedId = feedUrl,
          feedTitle = Atom.TextString title,
          -- Assumes at least one entry; maximum fails on an empty list.
          feedUpdated = maximum $ map Atom.entryUpdated entries,
          feedAuthors = nubBy ((==) `on` Atom.personURI) $ concatMap Atom.entryAuthors entries,
          feedCategories = map Atom.newCategory . nub . map Atom.catTerm . concatMap Atom.entryCategories $ entries,
          feedContributors = [],
          feedGenerator = Nothing,
          feedIcon = Nothing,
          feedLinks = [(Atom.nullLink feedUrl) {Atom.linkRel = Just $ Left "self"}, Atom.nullLink feedHtmlUrl],
          feedLogo = Nothing,
          feedRights = Just $ Atom.TextString $ "© " <> author.copyrightYear <> ", " <> author.name,
          feedSubtitle = Nothing,
          feedEntries = entries,
          feedAttrs = [],
          feedOther = []
        }

writeFeed :: Atom.URI -> Atom.URI -> T.Text -> String -> [Atom.Entry] -> RAction ()
writeFeed feedUrl feedHtmlUrl title out entries = do
  ctx <- ask
  lift $ case Atom.textFeed (mkFeed feedUrl feedHtmlUrl title ctx.config entries) of
    Nothing -> fail "Unable to create feed"
    Just content -> do
      writeFile out $ TL.toStrict content
      Shake.putInfo $ "Built " <> out
