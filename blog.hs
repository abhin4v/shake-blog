#! /usr/bin/env nix-shell
#! nix-shell -p "haskellPackages.ghcWithPackages (p: [p.mustache p.pandoc p.shake p.deriving-aeson p.feed])"
#! nix-shell -i runhaskell
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad (forM, void)
import Data.Aeson ((.=))
import Data.Aeson.Types qualified as A
import Data.Function (on)
import Data.HashMap.Strict qualified as HM
import Data.List (nub, nubBy, sortOn)
import Data.Maybe (maybeToList)
import Data.Ord qualified as Ord
import Data.Text qualified as T
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

buildTargets :: PostCache -> Action ()
buildTargets postCache = do
  assetPaths <- Shake.getDirectoryFiles "" assetGlobs
  Shake.need $ map (outputDir </>) assetPaths

  Shake.need $ map indexHtmlOutputPath pagePaths

  postPaths <- Shake.getDirectoryFiles "" postGlobs
  Shake.need $ map indexHtmlOutputPath postPaths
  Shake.need $ map (outputDir </>) ["feed.atom", "archive/index.html", "index.html"]

  posts <- forM postPaths postCache
  Shake.need
    [ outputDir </> "tags" </> T.unpack tag </> "index.html"
    | post <- posts,
      tag <- postTags $ postMeta post
    ]

assetGlobs :: [String]
assetGlobs = ["css/*.css", "images/*.png"]

pagePaths :: [String]
pagePaths = []

postGlobs :: [String]
postGlobs = ["posts/*.md"]

indexHtmlOutputPath :: FilePath -> FilePath
indexHtmlOutputPath srcPath =
  outputDir </> Shake.dropExtension srcPath </> "index.html"

buildRules :: TemplateCache -> PostCache -> Rules ()
buildRules templateCache postCache = do
  assets
  pages templateCache
  posts templateCache postCache
  postFeed postCache
  archive templateCache postCache
  tags templateCache postCache
  home templateCache postCache

assets :: Rules ()
assets =
  map (outputDir </>) assetGlobs |%> \target -> do
    Shake.need ["blog.hs"]
    let src = Shake.dropDirectory1 target
    Shake.copyFileChanged src target
    Shake.putInfo $ "Copied " <> target <> " from " <> src

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

pages :: TemplateCache -> Rules ()
pages templateCache =
  map indexHtmlOutputPath pagePaths |%> \target -> do
    Shake.need ["blog.hs"]
    let src = indexHtmlSourcePath target
    (meta, html) <- markdownToHtml @(HM.HashMap T.Text _) src

    page <- mkPage (meta HM.! "title") "page" html
    applyTemplateAndWrite templateCache "default.html" page target
    Shake.putInfo $ "Built " <> target <> " from " <> src

indexHtmlSourcePath :: FilePath -> FilePath
indexHtmlSourcePath =
  Shake.dropDirectory1
    . (<.> "md")
    . Shake.dropTrailingPathSeparator
    . Shake.dropFileName

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

posts :: TemplateCache -> PostCache -> Rules ()
posts templateCache postCache =
  map indexHtmlOutputPath postGlobs |%> \target -> do
    Shake.need ["blog.hs"]
    let src = indexHtmlSourcePath target
    post <- postCache src
    postHtml <- applyTemplate templateCache "post.html" post

    page <- mkPage (postTitle $ postMeta post) "post" postHtml
    applyTemplateAndWrite templateCache "default.html" page target
    Shake.putInfo $ "Built " <> target <> " from " <> src

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

type PostCache = FilePath -> Action Post

newPostCache :: IO PostCache
newPostCache = Shake.newCacheIO readPost

postFeed :: PostCache -> Rules ()
postFeed postCache =
  outputDir </> "feed.atom" %> \target -> do
    Shake.need ["blog.hs"]
    postPaths <- Shake.getDirectoryFiles "" postGlobs
    posts <- sortOn (Ord.Down . postDate) <$> forM postPaths postCache
    entries <- traverse (postEntry postCache) posts
    writeFeed (siteRoot <> "/feed.atom") "Abhinav Sarkar" siteTitle entries target

archive :: TemplateCache -> PostCache -> Rules ()
archive templateCache postCache =
  outputDir </> "archive/index.html" %> \target -> do
    Shake.need ["blog.hs"]
    postPaths <- Shake.getDirectoryFiles "" postGlobs
    posts <- sortOn (Ord.Down . postDate) <$> forM postPaths postCache
    writeArchive templateCache (T.pack "Archive") posts target

writeArchive :: TemplateCache -> T.Text -> [Post] -> FilePath -> Action ()
writeArchive templateCache title posts target = do
  baseUrl <- getBaseUrl
  html <-
    applyTemplate templateCache "archive.html" $
      A.object ["title" .= title, "posts" .= posts, "base_url" .= baseUrl]
  page <- mkPage title "archive" html
  applyTemplateAndWrite templateCache "default.html" page target
  Shake.putInfo $ "Built " <> target

tags :: TemplateCache -> PostCache -> Rules ()
tags templateCache postCache =
  outputDir </> "tags/*/index.html" %> \target -> do
    Shake.need ["blog.hs"]
    let tag = T.pack $ Shake.splitDirectories target !! 2
    postPaths <- Shake.getDirectoryFiles "" postGlobs
    posts <-
      sortOn (Ord.Down . postDate)
        . filter ((tag `elem`) . postTags . postMeta)
        <$> forM postPaths postCache
    writeArchive templateCache (T.pack "Posts tagged “" <> tag <> T.pack "”") posts target

home :: TemplateCache -> PostCache -> Rules ()
home templateCache postCache =
  outputDir </> "index.html" %> \target -> do
    Shake.need ["blog.hs"]
    postPaths <- Shake.getDirectoryFiles "" postGlobs
    posts <- take 5 . sortOn (Ord.Down . postDate) <$> forM postPaths postCache

    baseUrl <- getBaseUrl
    html <- applyTemplate templateCache "home.html" $ A.object ["posts" .= posts, "base_url" .= baseUrl]

    page <- mkPage "Home" "home" html
    applyTemplateAndWrite templateCache "default.html" page target
    Shake.putInfo $ "Built " <> target

markdownToHtml :: (FromJSON a) => FilePath -> Action (a, T.Text)
markdownToHtml filePath = do
  content <- Shake.readFile' filePath
  Shake.quietly . Shake.traced "Markdown to HTML" $ do
    pandoc@(Pandoc meta _) <-
      runPandoc . Pandoc.readMarkdown readerOptions . T.pack $ content
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

applyTemplate :: (ToJSON a) => TemplateCache -> String -> a -> Action T.Text
applyTemplate templateCache templateName context = do
  tmpl <- templateCache $ "templates" </> templateName
  case Mus.checkedSubstitute tmpl (A.toJSON context) of
    ([], text) -> return text
    (errs, _) ->
      fail $
        "Error while substituting template "
          <> templateName
          <> ": "
          <> unlines (map show errs)

applyTemplateAndWrite ::
  (ToJSON a) => TemplateCache -> String -> a -> FilePath -> Action ()
applyTemplateAndWrite templateCache templateName context outputPath =
  applyTemplate templateCache templateName context
    >>= Shake.writeFile' outputPath . T.unpack

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

type TemplateCache = FilePath -> Action Mus.Template

newTemplateCache :: IO TemplateCache
newTemplateCache = Shake.newCacheIO readTemplate

feedAuthor :: T.Text -> Atom.Person
feedAuthor authorName =
  Atom.Person
    { Atom.personName = authorName,
      Atom.personURI = Just "https://abhinavsarkar.net/about/",
      Atom.personEmail = Just "abhinav@abhinavsarkar.net",
      Atom.personOther = []
    }

postEntry :: PostCache -> Post -> Action Atom.Entry
postEntry postCache Post {postMeta = PostMeta {..}, ..} = do
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

writeFeed :: Atom.URI -> T.Text -> T.Text -> [Atom.Entry] -> String -> Action ()
writeFeed feedUrl authorName title entries out =
  case Atom.textFeed (mkFeed feedUrl authorName title entries) of
    Nothing -> fail "Unable to create feed"
    Just content -> do
      Shake.writeFile' out $ TL.unpack content
      Shake.putInfo $ "Built: " <> out
