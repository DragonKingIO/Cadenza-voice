# Images and the intro video

## Images

- Brand banners for the README and for GitHub's social preview live in `branding/social-preview/` (1200×630).
- Interface screenshots live in `images/`. They are rendered by the app's own preview tool, which uses a temporary
  configuration, so they contain nothing about any real user:

  ```sh
  "$BIN" --preview-brand-page=engines --preview-engine-tab=local --preview-brand-width=900 \
         --preview-brand-output=/tmp/local.png --preview-brand-height=640 --ui-language=en
  ```

  The off-screen render shows the selected sidebar row as a black block, so crop to the content area (everything right of the
  sidebar) before publishing. Do not publish a preview that shows a permission warning or scripted results (for example the
  model comparison sheet in preview mode uses made-up recognition output).
- Keep each image under about 300 KB, and write alt text.

## Intro video

Where to host it, and why:

| Place | Recommendation |
|---|---|
| **The website** | A short version (about 90 seconds or less, H.264 MP4, ideally under 20 MB) in `public/video/` of the website repository, played by a `<video preload="none" poster=...>` element. Nothing loads until the visitor presses play, and no third-party script is involved, which keeps the site's "no tracking" promise. |
| **YouTube and Bilibili** | The full-length version, for reach (Bilibili for Chinese-speaking viewers). Link to it from the website with a poster image rather than an embedded player, because an embedded player loads the platform's scripts. |
| **The GitHub README** | A poster image that links to the video. Alternatively drag a short MP4 (under 100 MB) into the README editor on GitHub; it is hosted by GitHub and plays inline, and it does not live in the repository. |
| **Never** | Commit video files to the Git repositories: a file can never be removed from history, and clones become slow. |

Spots already reserved: a comment near the top of both READMEs, and `VideoEmbed` in the website repository.
