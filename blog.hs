#! /usr/bin/env nix-shell
#! nix-shell -p "haskellPackages.ghcWithPackages (p: [p.mustache p.pandoc p.shake p.feed p.yaml])"
#! nix-shell -i "runhaskell --ghc-arg=-threaded"
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall -Wno-x-partial #-}

module Main where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans (lift)
import Data.Aeson (FromJSON, ToJSON, (.=))
import Data.Aeson.Types qualified as A
import Data.Function (on)
import Data.Functor ((<&>))
import Data.HashMap.Strict qualified as HM
import Data.List (find, nub, nubBy, sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord qualified as Ord
import Data.Text qualified as T
import Data.Text.IO.Utf8 qualified as TU
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Data.Yaml qualified as Yaml
import Development.Shake (Action, Rules, (%>), (|%>), (~>))
import Development.Shake qualified as Shake
import Development.Shake.FilePath ((<.>), (</>))
import Development.Shake.FilePath qualified as Shake
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
  when (null config.authors) $ do
    error $ "There should be at least one author"

  templateCache <- newTemplateCache
  postCache <- newPostCache config
  let ctx = Context config templateCache postCache

  Shake.shakeArgs Shake.shakeOptions $ do
    Shake.withTargetDocs "Build the site" $
      "build" ~> runRAction ctx buildTargets
    Shake.withTargetDocs "Clean the built site" $
      "clean" ~> Shake.removeFilesAfter outputDir ["//*"]

    Shake.withoutTargets $ runRRules ctx buildRules

-- Settings

outputDir :: FilePath
outputDir = "_site"

assetGlobs :: [Shake.FilePattern]
assetGlobs = ["css/*.css", "images/*.png"]

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

data AuthorConfig = AuthorConfig
  { name :: T.Text,
    uri :: T.Text,
    email :: T.Text,
    copyrightYear :: T.Text
  }
  deriving (Show)

data SiteConfig = SiteConfig
  { title :: T.Text,
    url :: T.Text,
    description :: T.Text,
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

type PostCache = FilePath -> Action Post

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

buildTargets :: RAction ()
buildTargets = do
  assetPaths <- getDirFiles assetGlobs
  postPaths <- getDirFiles postGlobs

  need assetPaths
  need $ map indexHtmlOutputPath pagePaths
  need $ map indexHtmlOutputPath postPaths
  need [feedFileName, archivePath </> "index.html", "index.html"]

  ctx <- ask
  posts <- forP postPaths $ getPost ctx.postCache
  need [indexHtmlOutputPath $ tagArchivePath </> T.unpack tag | post <- posts, tag <- post.meta.tags]

buildRules :: RRules ()
buildRules = do
  assetRules
  pageRules
  postRules
  postFeedRules
  archiveRules
  tagArchiveRules
  homeRules

-- Assets

assetRules :: RRules ()
assetRules =
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

pageRules :: RRules ()
pageRules =
  map indexHtmlOutputPath pagePaths |@> \target -> do
    let src = indexHtmlSourcePath target
    ctx <- ask
    baseUrl <- getBaseUrl ctx.config
    (meta, html) <- markdownToHtml baseUrl src

    mkPage (meta HM.! ("title" :: T.Text)) "page" html
      >>= applyTemplateAndWrite "default.html" target
    putInfo $ "Built " <> target <> " from " <> src

-- Posts

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

data Post = Post
  { meta :: PostMeta,
    date :: T.Text,
    dateTime :: UTCTime,
    content :: T.Text,
    url :: T.Text,
    baseUrl :: T.Text,
    config :: SiteConfig
  }
  deriving (Show)

instance ToJSON Post where
  toJSON Post {..} =
    A.object
      [ "meta" .= meta,
        "date" .= date,
        "date_time" .= dateTime,
        "content" .= content,
        "url" .= url,
        "base_url" .= baseUrl,
        "site" .= config
      ]

readPost :: (MonadAction m) => SiteConfig -> FilePath -> m Post
readPost config postPath = do
  dateTime <-
    parseTimeM False defaultTimeLocale "%Y-%-m-%-d"
      . take 10
      . Shake.takeBaseName
      $ postPath
  let date = T.pack $ formatTime @UTCTime defaultTimeLocale "%B %e, %Y" dateTime

  baseUrl <- getBaseUrl config
  (meta, content) <- markdownToHtml baseUrl postPath
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

getPosts :: RAction [Post]
getPosts = do
  ctx <- ask
  postPaths <- getDirFiles postGlobs
  sortOn (Ord.Down . date) <$> traverse (getPost ctx.postCache) postPaths

postRules :: RRules ()
postRules =
  map indexHtmlOutputPath postGlobs |@> \target -> do
    ctx <- ask
    let src = indexHtmlSourcePath target
    post <- getPost ctx.postCache src
    postHtml <- applyTemplate "post.html" post

    mkPage post.meta.title "post" postHtml
      >>= applyTemplateAndWrite "default.html" target
    putInfo $ "Built " <> target <> " from " <> src

postFeedRules :: RRules ()
postFeedRules =
  feedFileName @> \target -> do
    ctx <- ask
    getPosts
      >>= traverse mkPostEntry
      >>= writeFeed
        (ctx.config.url <> "/" <> T.pack feedFileName)
        ctx.config.title
        target

archiveRules :: RRules ()
archiveRules =
  (archivePath </> "index.html") @> \target ->
    getPosts >>= writeArchive (T.pack "Archive") target

writeArchive :: T.Text -> FilePath -> [Post] -> RAction ()
writeArchive title target posts = do
  ctx <- ask
  baseUrl <- getBaseUrl ctx.config
  html <-
    applyTemplate "archive.html" $
      A.object
        [ "title" .= title,
          "posts" .= posts,
          "base_url" .= baseUrl,
          "site" .= ctx.config
        ]
  mkPage title "archive" html >>= applyTemplateAndWrite "default.html" target
  putInfo $ "Built " <> target

tagArchiveRules :: RRules ()
tagArchiveRules =
  (tagArchivePath </> "*/index.html") @> \target -> do
    let tag = T.pack $ Shake.splitDirectories target !! 2
    getPosts
      <&> filter ((tag `elem`) . tags . meta)
      >>= writeArchive (T.pack "Posts tagged “" <> tag <> T.pack "”") target

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

prependOutputDir :: FilePath -> FilePath
prependOutputDir = (outputDir </>)

need :: (MonadAction m) => [FilePath] -> m ()
need = liftAction . Shake.need . map prependOutputDir

putInfo :: (MonadAction m) => String -> m ()
putInfo = liftAction . Shake.putInfo

copyFileChanged :: (MonadAction m) => FilePath -> FilePath -> m ()
copyFileChanged src dst = liftAction $ Shake.copyFileChanged src dst

getDirFiles :: (MonadAction m) => [Shake.FilePattern] -> m [FilePath]
getDirFiles = liftAction . Shake.getDirectoryFiles ""

forP :: (MonadAction m) => [a] -> (a -> Action b) -> m [b]
forP xs = liftAction . Shake.forP xs

(|@>) :: [Shake.FilePattern] -> (FilePath -> RAction ()) -> RRules ()
filePatterns |@> f = do
  ctx <- ask
  lift $
    map prependOutputDir filePatterns |%> \target ->
      Shake.need ["blog.hs", "config.yaml"] >> runRAction ctx (f target)

(@>) :: Shake.FilePattern -> (FilePath -> RAction ()) -> RRules ()
fp @> f = do
  ctx <- ask
  lift $
    prependOutputDir fp %> \target ->
      Shake.need ["blog.hs", "config.yaml"] >> runRAction ctx (f target)

indexHtmlOutputPath :: FilePath -> FilePath
indexHtmlOutputPath srcPath = Shake.dropExtension srcPath </> "index.html"

indexHtmlSourcePath :: FilePath -> FilePath
indexHtmlSourcePath =
  Shake.dropDirectory1
    . (<.> "md")
    . Shake.dropTrailingPathSeparator
    . Shake.dropFileName

readFile :: FilePath -> Action T.Text
readFile fp = do
  Shake.need [fp]
  content <- Shake.liftIO $ TU.readFile fp
  Shake.trackRead [fp]
  return content

writeFile :: FilePath -> T.Text -> Action ()
writeFile fp content = do
  Shake.liftIO $ TU.writeFile fp content
  Shake.trackWrite [fp]

-- Pandoc utils

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
    readerOptions =
      Pandoc.def {Pandoc.readerExtensions = Pandoc.pandocExtensions}
    writerOptions =
      Pandoc.def {Pandoc.writerExtensions = Pandoc.pandocExtensions}

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

    runPandoc action =
      Pandoc.runIO (Pandoc.setVerbosity Pandoc.ERROR >> action)
        >>= either (fail . show) return

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

readTemplate :: FilePath -> Action Mus.Template
readTemplate templatePath = do
  Shake.need [templatePath]
  eTemplate <-
    Shake.quietly
      . Shake.traced "Compile template"
      $ Mus.localAutomaticCompile templatePath
  case eTemplate of
    Right template -> do
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

mkPostEntry :: Post -> RAction Atom.Entry
mkPostEntry post@Post {meta} = do
  let siteUrl = post.config.url
      authors = post.config.authors
      entryUrl = if siteUrl `T.isPrefixOf` post.url then post.url else siteUrl <> post.url
      entryUpdated = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" post.dateTime
      entryAuthor = fromMaybe (head authors) $ meta.author >>= \n -> find ((== n) . name) authors
  return $
    Atom.Entry
      { entryId = entryUrl,
        entryTitle = Atom.TextString meta.title,
        entryUpdated = entryUpdated,
        entryAuthors = [feedAuthor entryAuthor],
        entryCategories = map (Atom.newCategory . T.strip) meta.tags,
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

mkFeed :: Atom.URI -> T.Text -> SiteConfig -> [Atom.Entry] -> Atom.Feed
mkFeed feedUrl title config entries =
  let author = head config.authors
   in Atom.Feed
        { feedId = feedUrl,
          feedTitle = Atom.TextString title,
          feedUpdated = maximum $ map Atom.entryUpdated entries,
          feedAuthors = nubBy ((==) `on` Atom.personURI) $ concatMap Atom.entryAuthors entries,
          feedCategories = map Atom.newCategory . nub . map Atom.catTerm . concatMap Atom.entryCategories $ entries,
          feedContributors = [],
          feedGenerator = Nothing,
          feedIcon = Nothing,
          feedLinks = [(Atom.nullLink feedUrl) {Atom.linkRel = Just $ Left "self"}, Atom.nullLink config.url],
          feedLogo = Nothing,
          feedRights = Just $ Atom.TextString $ "© " <> author.copyrightYear <> ", " <> author.name,
          feedSubtitle = Nothing,
          feedEntries = entries,
          feedAttrs = [],
          feedOther = []
        }

writeFeed :: Atom.URI -> T.Text -> String -> [Atom.Entry] -> RAction ()
writeFeed feedUrl title out entries = do
  ctx <- ask
  lift $ case Atom.textFeed (mkFeed feedUrl title ctx.config entries) of
    Nothing -> fail "Unable to create feed"
    Just content -> do
      writeFile out $ TL.toStrict content
      Shake.putInfo $ "Built " <> out
