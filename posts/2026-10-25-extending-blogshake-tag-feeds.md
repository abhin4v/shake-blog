---
title: Extending BlogShake with Per-Tag Atom Feeds
tags:
  - shake
  - guide
  - haskell
---

[BlogShake](https://github.com/abhin4v/shake-blog) is a minimal static site generator (SSG) built upon the [Shake] build system. It is extensible, but not in the usual way. Unlike most of SSGs, it has no plugin system. Instead, the users are expected to read and modify BlogShake code. Since it builds upon the solid foundation of Shake and [Pandoc], it is actually easy to extend in many possible directions. In this post, we walk through one such change: giving each tag its own Atom feed.

The current code already generates tag archive pages at `/tags/<tag>/` and a global feed at `/feed.atom`. We now want to generate `/tags/<tag>/feed.atom` to contain the same posts as the tag's archive. We already have the supporting pieces in `blog.hs`, we just have to bring them together.

## The Current `tagArchiveRules`

Here is the tag archive rule before the feed support exists:

```haskell
-- | Writes one archive page per tag.
tagArchiveRules :: RRules ()
tagArchiveRules =
  (tagArchivePath </> "*/index.html") @> \target -> do
    -- The tag is the path segment after tags/.
    let tag = T.pack $ Shake.splitDirectories target !! 2
    getPosts
      <&> filter (\post -> tag `elem` post.tags)
      >>= writeArchive
        (T.pack "Posts tagged “" <> tag <> T.pack "”")
        Nothing
        target
```

`tagArchiveRules` uses `@>`{.hs}, which crates a rule with one output. Shake matches the given pattern `tags/*/index.html` and calls the given action. In the action we extract the tag from the path, filter all posts by that tag, and use `writeArchive` to render and write the archive HTML file.

## Evolving `tagArchiveRules`

A tag's feed should contain the same posts as shown on the tag's archive page. We could add a separate rule for the `tags/*/feed.atom` pattern, but then we would have to filter the posts twice, wasting computation. Shake has a better fit for this case: the `&%>`{.hs} rule operator that builds a group of outputs with one action. The `&@>`{.hs} operator in BlogShake wraps it.

We change only the `tagArchiveRules`:

```haskell
-- | Writes one archive page and one Atom feed per tag.
tagArchiveRules :: RRules ()
tagArchiveRules =
  (map (\f -> tagArchivePath </> "*" </> f) ["index.html", feedFileName])
    &@> \[htmlTarget, atomTarget] -> do
      -- The tag is the path segment after tags/.
      let tag = T.pack $ Shake.splitDirectories htmlTarget !! 2
          title = T.pack "Posts tagged “" <> tag <> T.pack "”"
          tagPath = tagArchivePath </> T.unpack tag

      ctx <- ask
      taggedPosts <- filter (\post -> tag `elem` post.tags) <$> getPosts

      -- Write the HTML file
      writeArchive title (Just tag) htmlTarget taggedPosts
      -- Write the Atom file
      traverse mkPostEntry taggedPosts
        >>= writeFeed
          (ctx.config.url <> "/" <> T.pack (feedFileOutputPath tagPath))
          (ctx.config.url <> "/" <> T.pack tagPath <> "/")
          (ctx.config.title <> " — " <> title)
          atomTarget
```

The rule now lists both the `tags/*/index.html` and `tags/*/feed.atom` patterns, and `&@>`{.hs} registers a single handler action for the group that receives both paths at once. We extract the tag from `htmlTarget`, from which we build `tagPath` (for example `tags/haskell`). Unlike `htmlTarget`, `tagPath` does not include the `_site` output prefix, so we can use it directly in URLs in the final feed.

We compute `taggedPosts` once and reuse it for both HTML and Atom. `writeArchive` writes the HTML, `mkPostEntry` converts the posts to Atom entries, and `writeFeed` writes the feed. We pass `Just tag`{.hs} to `writeArchive` so the archive template can point its feed icon at the tag feed. We build the feed URL and feed HTML URL using `config.url`{.hs} because they need to be absolute. The feed title is the site title plus the tag archive title.

## How This Works

`buildTargets` only includes the HTML archive for each tag. Because `&@>`{.hs} registers both patterns as one output group, needing the HTML target builds the feed target too. We do not have to list the feed targets separately.

`writeArchive` already accepts a `Maybe tag`{.hs} and exposes a `tag_path` value to the `archive.html` template. The template uses that value to choose the feed link, pointing to either the global feed or a tag-wise feed.

## Build and Verify

Run:

```sh
./blog.hs build
ls _site/tags/haskell/
```

We should see both `feed.atom` and `index.html`.

## Conclusion

Our change is small because it builds upon the existing infrastructure of Shake and BlogShake. We changed one rule to produce two outputs from list of tagged posts, reusing the existing archive and feed helpers. This is how users are supposed to extend BlogShake instead of relying on a plugin system.

[Shake]: https://shakebuild.com/
[Pandoc]: https://pandoc.org/
