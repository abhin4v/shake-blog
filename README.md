# Shake Blog

Shake Blog is a starter template for building your own static site generator
using [Shake](https://shakebuild.com) and Haskell. It produces a blog with
posts, standalone pages, tag archives, and an Atom feed of posts.

It is **not** a turnkey blogging platform. You are expected to fork the
codebase and modify it as your site grows — tweak the templates, add new
page types, change the URL structure, wire in new build rules. The Haskell
source (`blog.hs`) is meant to be read and edited, not hidden away.

All dependencies are managed automatically by Nix via the shebang at the top
of `blog.hs` — there is no package manager or build tool to install.

## Prerequisites

- [Nix](https://nixos.org/download)

## Quick start

```sh
./blog.hs build
```

Open `_site/index.html` in your browser.

To enable parallel builds:

```sh
./blog.hs build -j4
```

Clean the output:

```sh
./blog.hs clean
```

Run `./blog.hs --help` to see all Shake build options (parallelism,
progress reporting, profile, etc.).

## Project structure

```
├── blog.hs              # the generator — edit to customize
├── config.yaml          # site identity (title, url, description, authors)
├── posts/               # markdown posts, one file per post
│   └── YYYY-MM-DD-*.md
├── templates/           # mustache templates
│   ├── default.html     # outer page layout
│   ├── home.html        # homepage
│   ├── post.html        # individual post
│   ├── archive.html     # post archive
│   ├── post-list.html   # shared post list partial
│   └── feed.svg         # feed icon partial
├── css/                 # static assets (copied verbatim)
│   └── default.css
└── _site/               # build output
```

## Configuration

Edit `config.yaml` to set your blog's title, URL, description, and authors:

```yaml
title: My Blog
url: https://example.com
description: A blog about things.
authors:
  - name: Your Name
    uri: https://example.com/about/
    email: you@example.com
    copyright_year: "2026"
```

The generator requires at least one author.

## Customizing the generator

The build settings live at the top of `blog.hs` under the comment `-- Settings`:

| Setting | Default | Description |
|---|---|---|
| `outputDir` | `"_site"` | Where the generated site goes |
| `assetGlobs` | `["css/*.css", "images/*.png"]` | Patterns for static files to copy verbatim |
| `postGlobs` | `["posts/*.md"]` | Glob pattern for finding post source files |
| `pagePaths` | `[]` | List of standalone Markdown page sources (e.g. `["about.md"]`) |
| `archivePath` | `"archive"` | Subdirectory for the post archive |
| `tagArchivePath` | `"tags"` | Subdirectory for per-tag post listings |
| `homePostCount` | `5` | Number of recent posts shown on the homepage |
| `feedFileName` | `"feed.atom"` | Name of the Atom feed file |

Everything else in `blog.hs` is meant to be read and modified as your site
grows — add new page types, change the URL structure, wire in new Shake
rules.

## Output

Running `./blog.hs build` produces this site structure under the output
directory (`_site` by default):

```
_site/
├── index.html                  # homepage
├── feed.atom                   # Atom feed
├── about/
│   └── index.html              # standalone page (if `about.md` in pagePaths)
├── css/
│   └── default.css             # copied verbatim from source
├── images/
│   └── ...                     # copied verbatim from source
├── archive/
│   └── index.html              # full post archive
├── tags/
│   ├── <tag>/
│   │   └── index.html          # per-tag post listing
│   └── ...
└── <post-slug>/
    └── index.html              # individual post
```

Each post and standalone page gets its own directory with an `index.html` so
URLs are clean (e.g. `/my-first-post/` or `/about/`).

## Writing posts

Posts live in `posts/` as Markdown files with YAML front matter. The filename
**must** start with `YYYY-MM-DD-` — the date is parsed from it.

```markdown
---
title: My first post
author: Your Name          # optional; defaults to the first author in config
tags:
  - haskell
  - shake
---

Post content goes here.
```

### Template variables

Post pages receive:

| Variable | Description |
|---|---|
| `{{meta.title}}` | Post title |
| `{{meta.author}}` | Post author (if set in front matter) |
| `{{meta.tags}}` | List of tags |
| `{{date}}` | Formatted date (e.g. "July 17, 2026") |
| `{{date_time}}` | ISO-8601 date (e.g. "2026-07-17T00:00:00Z") |
| `{{content}}` | Post body as HTML |
| `{{url}}` | Absolute URL of the post |
| `{{base_url}}` | Site base URL (empty in dev, `config.url` in prod) |
| `{{site}}` | Full site config object |

The `{{site}}` object exposes `{{site.title}}`, `{{site.url}}`,
`{{site.description}}`, `{{site.author}}` (first author), and
`{{site.authors}}` (all authors).

Page (non-post) templates receive `{{site}}`, `{{base_url}}`,
`{{title}}`, `{{main_class}}`, and `{{content}}`.

`{{main_class}}` is a CSS class name set per-page by the generator (e.g.
`"post"`, `"page"`, `"home"`, `"archive"`). It is set on `<main class="{{main_class}}">`
in the default template, letting you style different page types differently
without extra template logic.

### Environment and `{{base_url}}`

Set `ENV=PROD` when building for deployment:

```sh
ENV=PROD ./blog.hs build
```

In `PROD` mode, `{{base_url}}` is set to the `url` from `config.yaml`, so all
links point to your live site. When `ENV` is unset or set to anything else
(e.g. the default `DEV`), `{{base_url}}` is empty and links are relative —
ideal for opening `_site/index.html` directly from disk during development.

This means you can preview the site locally without a server, and the same
build produces absolute URLs when deployed. The only thing that changes is
the `{{base_url}}` variable; everything else (content, structure, output) is
identical between dev and prod builds.

## License

MIT
