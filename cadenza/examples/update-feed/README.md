# Trying the update check without a real repository

The update check normally asks the project's release page. Until one exists, you can try the whole flow against a
fake feed that lives only on this Mac. The app accepts a test feed only on `127.0.0.1` or `localhost`, so nothing is
ever sent to anyone.

```bash
cd examples/update-feed
python3 -m http.server 8765 &
/Applications/随言.app/Contents/MacOS/Yansui --update-feed-override=http://127.0.0.1:8765/latest.json
```

Open About and press Check for updates: it reports version 9.9.9 as available. Edit `tag_name` to `v1.0.0` to see
"latest version", or stop the server to see the failure message. The override is read from the launch argument only;
it is never saved.
