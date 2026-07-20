# BlogShake

BlogShake is a starter project for building your own static site generator using [Shake](https://shakebuild.com) and Haskell. It produces a blog with posts, standalone pages, tag archives, and an Atom feed of posts.

It is **not** a turnkey blogging platform. You are expected to fork the codebase and modify it as your site grows: tweak the templates, add new page types, change the URL structure, wire in new build rules. The Haskell source (`blog.hs`) is meant to be read and edited.

All dependencies are managed automatically by Nix via the shebang at the top of `blog.hs`. There is no package manager or build tool to install.

[BlogShake's website](https://abhin4v.github.io/shake-blog/) is created using itself. The blogposts are the documentation and demonstration for the project. Read them and read their source code to get started with the project.

## Contributing

I don't foresee adding any new features to BlogShake. It is meant to be forked and extended. I'll keep doing bugfixes, security fixes and dependency upgrades.

Please feel free to create an issue if you find a bug. I'm not inclined to accept pull requests unless there is a very compelling reason.

## Disclaimer

This is a personal project. The views, code, and opinions expressed here are my own and do not represent those of my current or past employers.
