#! /usr/bin/env nix-shell
#! nix-shell -p "haskellPackages.ghcWithPackages (p: [p.mustache p.pandoc p.shake p.deriving-aeson p.feed])"
#! nix-shell -i "runhaskell --ghc-arg=-threaded"
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}

module Main where

import Control.Monad (forM)
import Data.Aeson ((.=))
import Data.Aeson.Types qualified as A
import Data.Function (on)
import Data.Functor ((<&>))
import Data.HashMap.Strict qualified as HM
import Data.List (nub, nubBy, sortOn)
import Data.Maybe (maybeToList)
import Data.Ord qualified as Ord
import Data.Text qualified as T
import Data.Text.IO.Utf8 qualified as TU
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Deriving.Aeson
import Deriving.Aeson.Stock (PrefixedSnake)
import Development.Shake (Action, Rules, (%>), (|%>), (~>))
import Development.Shake qualified as Shake
import Development.Shake.FilePath ((<.>), (</>))
import Development.Shake.FilePath qualified as Shake
import Text.Atom.Feed qualified as Atom
import Text.Atom.Feed.Export qualified as Atom
import Text.Mustache qualified as Mus
import Text.Mustache.Compile qualified as Mus
import Text.Pandoc (Block (Plain), Meta (..), MetaValue (..), Pandoc (..))
import Text.Pandoc qualified as Pandoc
import Prelude hiding (readFile, writeFile)

main :: IO ()
main = do
  templateCache <- newTemplateCache
  postCache <- newPostCache

  Shake.shakeArgs Shake.shakeOptions $ do
    Shake.withTargetDocs "Build the site" $
      "build" ~> buildTargets postCache
    Shake.withTargetDocs "Clean the built site" $
      "clean" ~> Shake.removeFilesAfter outputDir ["//*"]

    Shake.withoutTargets $ buildRules templateCache postCache

outputDir :: String
outputDir = "_site"

siteRoot :: T.Text
siteRoot = "https://projects.abhinavsarkar.net/dum-blog"

siteTitle :: T.Text
siteTitle = "Dum Dev Blog"

assetGlobs :: [String]
assetGlobs = ["css/*.css", "images/*.png"]

pagePaths :: [String]
pagePaths = []

postGlobs :: [String]
postGlobs = ["posts/*.md"]

buildTargets :: PostCache -> Action ()
buildTargets postCache = do
  assetPaths <- Shake.getDirectoryFiles "" assetGlobs
  postPaths <- Shake.getDirectoryFiles "" postGlobs

  need assetPaths
  need $ map indexHtmlOutputPath pagePaths
  need $ map indexHtmlOutputPath postPaths
  need ["feed.atom", "archive/index.html", "index.html"]

  posts <- Shake.forP postPaths postCache
  need
    [ indexHtmlOutputPath $ "tags" </> T.unpack tag
    | post <- posts,
      tag <- postTags $ postMeta post
    ]

buildRules :: TemplateCache -> PostCache -> Rules ()
buildRules templateCache postCache = do
  assetRules
  pageRules templateCache
  postRules templateCache postCache
  postFeedRules postCache
  archiveRules templateCache postCache
  tagArchiveRules templateCache postCache
  homeRules templateCache postCache

-- Assets

assetRules :: Rules ()
assetRules =
  assetGlobs |@> \target -> do
    let src = Shake.dropDirectory1 target
    Shake.copyFileChanged src target
    Shake.putInfo $ "Copied " <> target <> " from " <> src

-- Pages

data Page = Page
  { pageTitle :: T.Text,
    pageMainClass :: T.Text,
    pageBaseUrl :: T.Text,
    pageContent :: T.Text
  }
  deriving (Show, Generic)
  deriving (ToJSON) via PrefixedSnake "page" Page

getBaseUrl :: Action T.Text
getBaseUrl =
  Shake.getEnvWithDefault "DEV" "ENV"
    >>= pure . \case
      "PROD" -> siteRoot
      _ -> ""

mkPage :: T.Text -> T.Text -> T.Text -> Action Page
mkPage title mainClass content = do
  baseUrl <- getBaseUrl
  pure $ Page title mainClass baseUrl content

pageRules :: TemplateCache -> Rules ()
pageRules templateCache =
  map indexHtmlOutputPath pagePaths |@> \target -> do
    let src = indexHtmlSourcePath target
    (meta, html) <- markdownToHtml @(HM.HashMap T.Text _) src

    page <- mkPage (meta HM.! "title") "page" html
    applyTemplateAndWrite templateCache "default.html" page target
    Shake.putInfo $ "Built " <> target <> " from " <> src

-- Posts

data PostMeta = PostMeta
  { postTitle :: T.Text,
    postAuthor :: Maybe T.Text,
    postTags :: [T.Text]
  }
  deriving (Show, Generic)
  deriving (FromJSON, ToJSON) via PrefixedSnake "post" PostMeta

data Post = Post
  { postMeta :: PostMeta,
    postDate :: T.Text,
    postDateTime :: UTCTime,
    postContent :: T.Text,
    postUrl :: T.Text,
    postBaseUrl :: T.Text
  }
  deriving (Show, Generic)
  deriving (ToJSON) via PrefixedSnake "post" Post

type PostCache = FilePath -> Action Post

readPost :: FilePath -> Action Post
readPost postPath = do
  date <-
    parseTimeM False defaultTimeLocale "%Y-%-m-%-d"
      . take 10
      . Shake.takeBaseName
      $ postPath
  let formattedDate =
        T.pack $ formatTime @UTCTime defaultTimeLocale "%B %e, %Y" date

  (postMeta, html) <- markdownToHtml postPath
  Shake.putInfo $ "Read " <> postPath

  baseUrl <- getBaseUrl
  return $
    Post
      { postMeta,
        postDate = formattedDate,
        postDateTime = date,
        postContent = html,
        postUrl = baseUrl <> "/" <> T.pack (Shake.dropExtension postPath) <> "/",
        postBaseUrl = baseUrl
      }

newPostCache :: IO PostCache
newPostCache = Shake.newCacheIO readPost

getPosts :: PostCache -> Action [Post]
getPosts postCache = do
  postPaths <- Shake.getDirectoryFiles "" postGlobs
  sortOn (Ord.Down . postDate) <$> forM postPaths postCache

postRules :: TemplateCache -> PostCache -> Rules ()
postRules templateCache postCache =
  map indexHtmlOutputPath postGlobs |@> \target -> do
    let src = indexHtmlSourcePath target
    post <- postCache src
    postHtml <- applyTemplate templateCache "post.html" post

    page <- mkPage (postTitle $ postMeta post) "post" postHtml
    applyTemplateAndWrite templateCache "default.html" page target
    Shake.putInfo $ "Built " <> target <> " from " <> src

postFeedRules :: PostCache -> Rules ()
postFeedRules postCache =
  "feed.atom" @> \target ->
    getPosts postCache
      >>= traverse mkPostEntry
      >>= writeFeed (siteRoot <> "/feed.atom") "Abhinav Sarkar" siteTitle target

archiveRules :: TemplateCache -> PostCache -> Rules ()
archiveRules templateCache postCache =
  "archive/index.html" @> \target ->
    getPosts postCache
      >>= writeArchive templateCache (T.pack "Archive") target

writeArchive :: TemplateCache -> T.Text -> FilePath -> [Post] -> Action ()
writeArchive templateCache title target posts = do
  baseUrl <- getBaseUrl
  html <-
    applyTemplate templateCache "archive.html" $
      A.object ["title" .= title, "posts" .= posts, "base_url" .= baseUrl]
  page <- mkPage title "archive" html
  applyTemplateAndWrite templateCache "default.html" page target
  Shake.putInfo $ "Built " <> target

tagArchiveRules :: TemplateCache -> PostCache -> Rules ()
tagArchiveRules templateCache postCache =
  "tags/*/index.html" @> \target -> do
    let tag = T.pack $ Shake.splitDirectories target !! 2
    getPosts postCache
      <&> filter ((tag `elem`) . postTags . postMeta)
      >>= writeArchive templateCache (T.pack "Posts tagged “" <> tag <> T.pack "”") target

homeRules :: TemplateCache -> PostCache -> Rules ()
homeRules templateCache postCache =
  "index.html" @> \target -> do
    posts <- take 5 <$> getPosts postCache

    baseUrl <- getBaseUrl
    html <- applyTemplate templateCache "home.html" $ A.object ["posts" .= posts, "base_url" .= baseUrl]

    page <- mkPage "Home" "home" html
    applyTemplateAndWrite templateCache "default.html" page target
    Shake.putInfo $ "Built " <> target

-- Shake utils

prependOutputDir :: FilePath -> FilePath
prependOutputDir = (outputDir </>)

need :: [FilePath] -> Action ()
need = Shake.need . map prependOutputDir

(|@>) :: [Shake.FilePattern] -> (FilePath -> Action ()) -> Rules ()
filePatterns |@> action =
  map prependOutputDir filePatterns |%> \target ->
    Shake.need ["blog.hs"] >> action target

(@>) :: Shake.FilePattern -> (FilePath -> Action ()) -> Rules ()
filePattern @> action =
  prependOutputDir filePattern %> \target ->
    Shake.need ["blog.hs"] >> action target

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
  content <- Shake.liftIO $ TU.readFile fp
  Shake.trackRead [fp]
  return content

writeFile :: FilePath -> T.Text -> Action ()
writeFile fp content = do
  Shake.liftIO $ TU.writeFile fp content
  Shake.trackWrite [fp]

-- Pandoc utils

markdownToHtml :: (FromJSON a) => FilePath -> Action (a, T.Text)
markdownToHtml filePath = do
  content <- readFile filePath
  Shake.quietly . Shake.traced "Markdown to HTML" $ do
    pandoc@(Pandoc meta _) <- runPandoc $ Pandoc.readMarkdown readerOptions content
    meta' <- fromMeta meta
    html <- runPandoc . Pandoc.writeHtml5String writerOptions $ pandoc
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

-- Mustache utils

type TemplateCache = FilePath -> Action Mus.Template

applyTemplate :: (ToJSON a) => TemplateCache -> String -> a -> Action T.Text
applyTemplate templateCache templateName context = do
  tmpl <- templateCache $ "templates" </> templateName
  case Mus.checkedSubstitute tmpl (A.toJSON context) of
    ([], text) -> return text
    (errs, _) ->
      fail $ "Error while substituting template " <> templateName <> ": " <> unlines (map show errs)

applyTemplateAndWrite ::
  (ToJSON a) => TemplateCache -> String -> a -> FilePath -> Action ()
applyTemplateAndWrite templateCache templateName context outputPath =
  applyTemplate templateCache templateName context >>= writeFile outputPath

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

feedAuthor :: T.Text -> Atom.Person
feedAuthor authorName =
  Atom.Person
    { Atom.personName = authorName,
      Atom.personURI = Just "https://abhinavsarkar.net/about/",
      Atom.personEmail = Just "abhinav@abhinavsarkar.net",
      Atom.personOther = []
    }

mkPostEntry :: Post -> Action Atom.Entry
mkPostEntry Post {postMeta = PostMeta {..}, ..} = do
  let url = if siteRoot `T.isPrefixOf` postUrl then postUrl else siteRoot <> postUrl
      updated = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" postDateTime
  return $
    Atom.Entry
      { entryId = url,
        entryTitle = Atom.TextString postTitle,
        entryUpdated = updated,
        entryAuthors = maybeToList $ fmap feedAuthor postAuthor,
        entryCategories = map (Atom.newCategory . T.strip) postTags,
        entryContent = Just $ Atom.HTMLContent postContent,
        entryContributor = [],
        entryLinks = [(Atom.nullLink url) {Atom.linkRel = Just $ Left "alternate"}],
        entryPublished = Just updated,
        entryRights = Atom.TextString . ("© 2026, " <>) <$> postAuthor,
        entrySource = Nothing,
        entrySummary = Nothing,
        entryInReplyTo = Nothing,
        entryInReplyTotal = Nothing,
        entryAttrs = [],
        entryOther = []
      }

mkFeed :: Atom.URI -> T.Text -> T.Text -> [Atom.Entry] -> Atom.Feed
mkFeed feedUrl authorName title entries =
  Atom.Feed
    { feedId = feedUrl,
      feedTitle = Atom.TextString title,
      feedUpdated = maximum $ map Atom.entryUpdated entries,
      feedAuthors = nubBy ((==) `on` Atom.personURI) $ concatMap Atom.entryAuthors entries,
      feedCategories = map Atom.newCategory . nub . map Atom.catTerm . concatMap Atom.entryCategories $ entries,
      feedContributors = [],
      feedGenerator = Nothing,
      feedIcon = Nothing,
      feedLinks = [(Atom.nullLink feedUrl) {Atom.linkRel = Just $ Left "self"}, Atom.nullLink siteRoot],
      feedLogo = Nothing,
      feedRights = Just $ Atom.TextString $ "© 2026, " <> authorName,
      feedSubtitle = Nothing,
      feedEntries = entries,
      feedAttrs = [],
      feedOther = []
    }

writeFeed :: Atom.URI -> T.Text -> T.Text -> String -> [Atom.Entry] -> Action ()
writeFeed feedUrl authorName title out entries =
  case Atom.textFeed (mkFeed feedUrl authorName title entries) of
    Nothing -> fail "Unable to create feed"
    Just content -> do
      writeFile out $ TL.toStrict content
      Shake.putInfo $ "Built " <> out
