# Shake Blog

Shake Blog is a starter template for building your own static site generator using [Shake](https://shakebuild.com) and Haskell. It produces a blog with posts, standalone pages, tag archives, and an Atom feed of posts.

It is **not** a turnkey blogging platform. You are expected to fork the codebase and modify it as your site grows — tweak the templates, add new page types, change the URL structure, wire in new build rules. The Haskell source (`blog.hs`) is meant to be read and edited, not hidden away.

All dependencies are managed automatically by Nix via the shebang at the top of `blog.hs` — there is no package manager or build tool to install.

See the [getting started guide](https://abhin4v.github.io/shake-blog/posts/2026-07-19-getting-started/) for detailed usage instructions.
