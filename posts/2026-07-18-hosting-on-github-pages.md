---
title: Hosting BlogShake on GitHub Pages
tags:
  - guide
  - github-pages
---

Run a BlogShake blog on GitHub Actions and Pages: fork the repo, set the config, and let the Action build and publish the site for you.

## Quickstart

1. Fork this [repository](https://github.com/abhin4v/shake-blog/fork) on GitHub or use it as a [template](https://github.com/new?template_name=shake-blog&template_owner=abhin4v).
2. Edit [`config.yaml`](https://github.com/abhin4v/shake-blog/blob/main/config.yaml):
   set your site's title, URL, description, and authors.
3. [Set up the GitHub Action](#setting-up-the-github-action).
4. [Set up GitHub Pages](#setting-up-github-pages).
5. Push your changes. The action builds the site and publishes it.

## Setting up the GitHub Action

The workflow at
[`.github/workflows/build.yml`](https://github.com/abhin4v/shake-blog/blob/main/.github/workflows/build.yml) runs on every push to `main` and on manual dispatch. It builds the site and pushes the result to a `gh-pages` branch.

1. In your fork, go to **Settings > Actions > General**.
2. Under **Workflow permissions**, select **Read and write permissions** and click **Save**. This lets the workflow create and update the `gh-pages` branch.
3. Go to the **Actions** tab. If Actions are disabled on your fork, click *I understand my workflows, go ahead and enable them*.
4. Open the **Build** workflow and click **Enable workflow**.
5. Click **Run workflow** to trigger the first build manually.
6. Wait for the run to finish. It will create a `gh-pages` branch in your fork containing the generated site.

## Setting up GitHub Pages

After the first successful Action run has created the `gh-pages` branch:

1. Go to **Settings > Pages**.
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**.
3. Set **Branch** to `gh-pages` and the folder to `/ (root)`. Click **Save**.
4. Wait a minute, then refresh the Pages settings page. GitHub will show
   the public URL, e.g. `https://<you>.github.io/<repo>/`.

If you use a custom domain, add a `CNAME` file to the repo root containing your domain (the workflow copies it into `_site/` so it lands at the root of the `gh-pages` branch), and configure the domain under **Settings > Pages > Custom domain**. Without the `CNAME` file in the published branch, GitHub clears the custom-domain setting on every deploy. Update the `url` config in `config.yaml` to match your custom URL.
