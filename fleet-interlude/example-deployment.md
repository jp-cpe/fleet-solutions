# Example deployment

This is one working way to run Fleet Interlude in production for BYOD hosts. 

## Overview

## Steps

1. Create a new fleet named `BYOD staging`.
2. In the `BYOD staging` fleet, add self-service software titles for each item you want to install during Interlude (supports custom packages, script-only packages, Fleet-maintained apps, and VPP apps).
2. Customize `fleet-interlude.sh` to your needs.
3. Upload `fleet-interlude.sh` to the `BYOD staging` fleet.
4. Create a new Policy in the `BYOD staging` fleet named **macOS - Fleet Interlude complete** that fails until the sentinel exists. Its `run_script` automation is `fleet-interlude.sh`.
   
    ```sql
    SELECT 1 FROM file WHERE path = '/var/db/fleet-interlude.done'
    ```

5. Create a new Policy in the `BYOD staging` fleet named **macOS - BYOD Interlude verified** that passes when the sentinel, and the software you intended to install all exist.
    

    ```sql
    SELECT 1 WHERE
  EXISTS (
    SELECT 1 FROM file WHERE path = '/var/db/fleet-interlude.done'
  )
  AND EXISTS (
    SELECT 1 FROM apps WHERE bundle_identifier = 'com.google.Chrome'
  )
  AND EXISTS (
    SELECT 1 FROM file WHERE path = '/Applications/Fleet Desktop.app'
  )
  AND EXISTS (
    SELECT 1 FROM file WHERE path = '/var/db/some-pig.ran'
  )

    ```

> Keep **other policies/automations** out of the `BYOD staging` fleet (FileVault, patch policies, and so on) unless needed for Interlude. This keeps them from queueing work before Interlude runs.

7. Once a host passes the **macOS - BYOD Interlude verified** policy it can be moved to your production fleet.

> *Optional* – Use Tines or another automation platform to [automatically transfer verified hosts to your production fleet](https://fleetdm.com/docs/rest-api/rest-api#update-hosts-fleet) and surface notifications/errors into Slack.

## Fleets

- **BYOD Staging** has only the two Interlude policies and any self-service Software required for the Interlude run. It has no other automations or unrelated OS settings

- **Workstations** (your production fleet) has the full policy set, software, and OS settings. ADE Macs enroll here.



## Policies

- **macOS - Fleet Interlude complete** fails until the sentinel exists. Its `run_script` automation is `fleet-interlude.sh`. It applies on Workstations (through the macOS policies glob) and on BYOD Staging.
- **macOS - BYOD Interlude verified** is query-only and applies only on BYOD Staging. It passes when the sentinel, Google Chrome, Fleet Desktop, and `/var/db/some-pig.ran` all exist. It has no script, so it can't queue work ahead of Interlude.
- **Other Workstations policies** (FileVault, updates, Dock, and so on) pass until the sentinel exists. This keeps them from queueing work before Interlude runs.

## Automations

The org activities webhook (`default.yml`, sent to `$ACTIVITIES_WEBHOOK_URL`) posts Fleet activities to Tines, which runs two stories:

- **`tines/fleet-enrollment-slack.json`** posts to Slack on `mdm_enrolled`. It queues Interlude only if the host is already on Workstations, as a backup for ADE and manual enrollments.
- **`tines/byod-staging-promote.json`** lists Staging Macs every 2 minutes. When a Mac's verified policy passes, it calls `POST /hosts/transfer` to move the Mac to Workstations. It posts to Slack if the transfer returns a 4xx or 5xx error, or if a Mac has the sentinel but is missing the apps. It never starts Interlude.

