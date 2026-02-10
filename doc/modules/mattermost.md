# Mattermost module

The `mattermost/` module deploys a local Mattermost instance pre-configured with channels for Elastic alert notifications. It lets you develop and test Kibana alerting rules with a real messaging destination, end-to-end.

## What it provides

When the stack starts with the `mattermost` profile, the module sets up:

- **Mattermost instance** — a local chat server accessible in the browser
- **Pre-configured teams and channels** — teams with `elastic alerts` channels, matching the organization's structure
- **Kibana connector target** — a ready-to-use destination for Kibana alerting rules that send notifications via webhook

## What you can do as a user

- **Test Kibana alerting rules** — create an alerting rule in Kibana that fires a webhook to the local Mattermost instance, and verify the notification appears in the right channel
- **Develop Mattermost connectors** — configure and test the Kibana Mattermost connector action without needing access to a shared Mattermost server
- **Validate alert routing** — check that alerts from different teams or log categories arrive in the correct channels
- **Iterate on alert formatting** — tweak the alert message template and see the result instantly in Mattermost

## Compose profile

Mattermost is opt-in. Add `--profile mattermost` to enable it (typically combined with Kibana):

```bash
podman compose -f install/compose.yaml --env-file install/local/.env \
  --profile kibana --profile mattermost up -d
```
