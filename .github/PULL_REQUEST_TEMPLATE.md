## What and why

<!-- What changed, and why. Link the issue if there is one. -->

## How it was tested

<!-- Commands you ran, and their result. -->

## What I could not test

<!-- Real microphone, real provider account, real third-party app, other macOS versions… "Nothing" is fine if true. -->

## Checklist

- [ ] Builds with `./cadenza/build.sh --stage-only` and the self-test suites pass (see `cadenza/docs/DEVELOPING.md`)
- [ ] Behavior changes come with a test that fails without the change
- [ ] No new network request, telemetry or permission, or it is off by default and explained above
- [ ] Recordings, transcripts and credentials are never written to disk or logs
- [ ] `cadenza/tools/check-no-secrets.sh --staged` is clean
- [ ] User-facing text is in `Localizable.strings` for English and Chinese
- [ ] Commits are signed off (`git commit -s`)
