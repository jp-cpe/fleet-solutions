# Example deployment

This is one working example of how to run Interlude in production. It uses a dedicated fleet as a waiting room for manually enrolled Macs, whether they are BYOD, contractor-owned, or corporate Macs migrating from another MDM.

## Goal

| User story  |
|:---------------------------------------------------------------------------|
| As an IT admin,
| I want a specific set of software to install, in order, on manually enrolled macOS hosts immediately after enrollment and before anything else,
| so that I can confirm each new host meets a standardized, base-level configuration before it is transferred to our production fleet.


## Overview

Newly enrolled hosts land in a staging fleet, Interlude runs there on the host's first check-in, a second policy verifies the result, and verified hosts move to production.

The staging fleet does three jobs:

- **Its enroll secret is the filter.** Only hosts enrolled with the staging fleet's link get Interlude. Existing hosts and ADE enrollments never land there, so you don't need a label to tell a new manual enrollment apart from a migration or an existing host.
- **It keeps Interlude first.** Fleet doesn't let you order policy automations ([fleetdm/fleet#29921](https://github.com/fleetdm/fleet/issues/29921)). Keeping every other policy, automation, and software title out of the staging fleet is the reliable way to make sure nothing else queues work before Interlude runs.
- **It avoids label timing.** Labels and policies are both evaluated on a new host's first check-in, so a policy gated by a label can fire earlier or later than you expect ([fleetdm/fleet#49083](https://github.com/fleetdm/fleet/issues/49083) was a bug in this area). A fleet boundary has no such race.

If you require end user authentication on your manual enrollment link, turn it on for the staging fleet too. The enroll secret decides which fleet's settings apply, so IdP sign-in and user-to-host mapping only happen when the secret belongs to a fleet that requires it.

## Steps

1. Create a new fleet named `Manual enrollment staging`.
2. In that fleet, add a self-service software title for each item you want Interlude to install. Custom packages, script-only packages, Fleet-maintained apps, and App Store (VPP) apps all work. VPP apps require the host to be MDM-enrolled in Fleet; the others need only fleetd.
3. Customize `fleet-interlude.sh` to your needs. At minimum, set `STEPS` to your title names in the order you want them installed.
4. Upload `fleet-interlude.sh` to the staging fleet under **Controls > Scripts**.
5. Create a policy in the staging fleet named **macOS - Fleet Interlude complete** that fails until the sentinel exists. Set its run-script automation to `fleet-interlude.sh`. A new host fails this policy on its first check-in, which is what starts Interlude.

    ```sql
    SELECT 1 FROM file WHERE path = '/var/db/fleet-interlude.done';
    ```

6. Create a policy in the staging fleet named **macOS - Fleet Interlude verified** that passes only when the sentinel and every title you intended to install are present. Each `EXISTS` below maps to one `STEPS` entry. The last one checks a file that the example script-only package writes.

    ```sql
    SELECT 1 WHERE
      EXISTS (SELECT 1 FROM file WHERE path = '/var/db/fleet-interlude.done')
      AND EXISTS (SELECT 1 FROM apps WHERE bundle_identifier = 'com.google.Chrome')
      AND EXISTS (SELECT 1 FROM file WHERE path = '/Applications/Fleet Desktop.app')
      AND EXISTS (SELECT 1 FROM file WHERE path = '/var/db/some-pig.ran');
    ```

7. Keep **all other policies, automations, and software** out of the staging fleet unless Interlude needs them.
8. Hand out only the staging fleet's enrollment link for manual enrollments.
9. Once a host passes **macOS - Fleet Interlude verified**, transfer it to your production fleet.

> *Optional*: Use Tines or another automation platform to [transfer verified hosts to your production fleet](https://fleetdm.com/docs/rest-api/rest-api#update-hosts-fleet) and surface failures in Slack.

## GitOps equivalent

The same deployment in Fleet GitOps. Paths are relative to the file they appear in, so adjust them to your repo layout. Unrelated keys are omitted.

```yaml
# fleets/manual-enrollment-staging.yml
name: Manual enrollment staging
policies:
  - path: ../lib/macos/policies/fleet-interlude.yml
controls:
  scripts:
    - path: ../lib/macos/scripts/fleet-interlude.sh
software:
  fleet_maintained_apps:
    - slug: google-chrome/darwin
      self_service: true
  packages:
    - path: ../lib/macos/software/some_pig.sh
      display_name: some_pig.sh
      self_service: true
```

```yaml
# lib/macos/policies/fleet-interlude.yml
- name: macOS - Fleet Interlude complete
  platform: darwin
  description: Fails until Fleet Interlude has finished installing baseline software on this host.
  resolution: Fleet runs fleet-interlude.sh automatically. If it failed, re-run the script from Host details.
  query: SELECT 1 FROM file WHERE path = '/var/db/fleet-interlude.done';
  run_script:
    path: ../scripts/fleet-interlude.sh

- name: macOS - Fleet Interlude verified
  platform: darwin
  description: Passes when Interlude finished and every baseline title is installed. Hosts that pass can move to production.
  resolution: Check /var/log/fleet-interlude.log on the host.
  query: >-
    SELECT 1 WHERE
      EXISTS (SELECT 1 FROM file WHERE path = '/var/db/fleet-interlude.done')
      AND EXISTS (SELECT 1 FROM apps WHERE bundle_identifier = 'com.google.Chrome')
      AND EXISTS (SELECT 1 FROM file WHERE path = '/var/db/some-pig.ran');
```

## Re-enrollment and retries

- **Re-enrolling a wiped Mac.** The sentinel lives on disk, so a wiped Mac runs Interlude again once it re-enrolls into the staging fleet. Fleet, however, keeps a non-ADE host's previous policy results and label memberships until they refresh, so the host can briefly show **Fleet Interlude verified** as passing. If you automate the transfer to production, delete the host from Fleet before re-enrolling it. That is Fleet's current guidance for non-ADE hosts.
- **A failed run.** Fleet's run-script automation fires when the policy first fails, not on every failing run. If Interlude ends with a failed step, the sentinel is not written, the host stays in staging, and the script does not re-run on its own. Fix the title, then re-run the script from **Host details > Actions > Run script**.
