# Publishing Omahevy

The marketplace lists public GitHub repositories that carry a valid root
`manifest.json`. Everything below is copy-paste ready once the repo is public.

## 1. Push the repository

```sh
cd ~/code/oma-hevy
git remote add origin git@github.com:<your-username>/oma-hevy.git
git push -u origin main
```

Make sure the repository is **public** and that the README renders the preview:

```
https://github.com/<your-username>/oma-hevy
```

## 2. Smoke-test a clean install

```sh
omarchy plugin remove fbaroni.oma-hevy --yes
omarchy plugin add https://github.com/<your-username>/oma-hevy.git --enable
```

Click the bar widget, paste an API key, confirm the dashboard opens and syncs.
`omarchy plugin validate ~/.config/omarchy/plugins/fbaroni.oma-hevy` should
exit 0.

## 3. Submit the marketplace issue

Open this form:

<https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml>

Suggested answers:

| Field | Value |
| --- | --- |
| Title | `[Plugin]: Omahevy` |
| Repository URL | `https://github.com/<your-username>/oma-hevy` |
| Category | `Widgets` |
| Tags | `Bar`, `Quickshell` (max three; these two fit) |
| Suggested missing tag | `Fitness` |
| Maintainer notes | see below |

Maintainer notes to paste:

> Hevy training dashboard for the Omarchy bar. The bar shows weekly training
> volume; clicking opens a centered overlay with weekly target, consistency
> heatmap, 12-week volume chart, muscle balance, recent sessions and top lifts.
>
> Requirements: a Hevy account with public API access (Hevy Pro) and its API
> key, plus `python3` (standard library only). The key is stored locally in
> `~/.config/omarchy/hevy/config.json` (0600); the plugin only talks to
> `api.hevyapp.com` and has no telemetry. The preview screenshot uses the
> built-in sample data, not real account data.
>
> Not affiliated with Hevy.

Checklist:

- [x] Repository is public and contains installation/removal instructions.
- [x] License (MIT) and external dependencies (Python 3, Hevy Pro API) are documented.
- [x] I own the code and the preview asset.
- [x] The plugin does not overwrite user configuration without consent.
- [x] I understand listing is not a security review.

## 4. After approval

- Tag the release (`git tag v1.0.0 && git push --tags`).
- Keep the manifest `id` (`fbaroni.oma-hevy`) stable forever: installs and
  marketplace entries key off it.
- Update the marketplace entry with the same issue form if the repository or
  description changes.
