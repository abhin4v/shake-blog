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

All dependencies are managed by [Magix] which uses [Nix] underneath. No compilation is needed to run the generator.

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

## Common Shake Flags

Since BlogShake is a Shake build script, the standard [Shake] command-line flags work out of the box. Run `./blog.hs --help` to see the full list. The common ones are:

`-j N`, `--jobs=N`
: Build with `N` threads in parallel (default: one per CPU).

`--digest`
: Rebuild files when their content changes, not just their modification time. More robust on systems that touch files without changing them, and it is what the CI workflow uses.

`--color`
: Colorize the output.
`-q`, `--quiet`
: Print less; pass it again for even less.

`-p[N]`, `--progress[=N]`
: Show a progress line every `N` seconds (default 5).

`-k`, `--keep-going`
: Keep building the remaining targets even if some fail.

`-B`, `--rebuild`
: Force rebuild files even if nothing has changed.

`-r`, `--report`
: Write a profiling report to `report.html`.

`--prune`
: After a successful build, delete generated files that the current sources no longer produce. Used in CI to keep the published site in sync when posts or tags are removed

Examples:

```sh
./blog.hs -j4 --color build
./blog.hs -j4 --color --digest --prune build # what CI does
```

[Shake]: https://shakebuild.com/
[Pandoc]: https://pandoc.org/
[Magix]: https://github.com/dschrempf/magix
[Nix]: https://nixos.org/
