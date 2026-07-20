---
title: BlogShake Features in Detail
tags:
  - shake
  - guide
author: Abhinav Sarkar
---

Most static site generators are applications with conventions and plugins. They work well until you need something they didn't anticipate. BlogShake takes a different approach: a working [Shake] build script that you are meant to read and modify. This post covers its main features. For getting started, see [Getting Started with BlogShake](/posts/2026-07-19-getting-started/).

## Build System Approach

[Shake] is a build system written in [Haskell](https://haskell.org). It can be used to build anything, in this case we use it to build a website. Building on Shake gives us parallelism, incremental rebuilds, caching, profiling, and detailed error messages for free[^existing].

[^existing]: See [Slick](https://github.com/ChrisPenner/slick) and [Rib](https://github.com/srid/rib) for other Shake-based SSGs. BlogShake differs by exposing Shake directly rather than hiding it behind a framework.

## Zero-Setup Dependencies

All dependencies are managed by [Nix]. No compilation is needed to run the generator.

## Pandoc-Based Rendering

Posts are Markdown files with YAML front matter. We get [Pandoc]'s full Markdown support: footnotes, definition lists, tables, math, syntax highlighting.

Alongside posts, standalone pages (about, contact, etc.) can be added via the `pagePaths` setting. They work the same way but skip dates and tags.

The site configuration supports multiple author profiles with name, URI, email, and copyright year. Posts can override the default author via front matter, and the Atom feed resolves each post to the matching author's full profile for proper attribution.

### Code Highlighting

Code blocks are highlighted by Pandoc using CSS classes. The default stylesheet provides syntax highlighting colors for code tokens. It uses the `light-dark()` function so that highlighting adapts to light and dark modes automatically.

## Clean URLs

Every page gets its own directory with an `index.html`, so no `.html` extensions:

```{.plain}
_site/posts/my-first-post/index.html  ->  /posts/my-first-post/
_site/contact/index.html              ->  /contact/
```

## Responsive CSS with Dark Mode Support

The blog looks good on all screen sizes due to responsive CSS. Light and dark modes are also supported using the CSS `light-dark()` function.

## Dev and Prod Modes

Set `ENV=PROD` for absolute URLs, unset for relative:

```sh
./blog.hs build              # relative URLs, open locally
ENV=PROD ./blog.hs build     # absolute URLs, deploy
```

Only the `base_url` variable changes between modes. Content and structure are identical.

## Atom Feed, Archives, and Tags

The generator produces an Atom feed at `/feed.atom`, a reverse-chronological archive at `/archive/`, and per-tag pages at `/tags/<tag>/`.

## CI/CD

The included GitHub Actions workflow builds the site with `ENV=PROD` and publishes to GitHub Pages on every push. See the [hosting guide](/posts/2026-07-18-hosting-on-github-pages/) for setup.

## Extensibility

Everything lives in `blog.hs`, organized into labeled sections. Extend `blog.hs` to add any functionality you want to your website. The full Shake API is available to you.

[Shake]: https://shakebuild.com/
[Pandoc]: https://pandoc.org/
[Nix]: https://nixos.org/
