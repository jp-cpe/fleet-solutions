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

> Keep **all other unrelated policies, automations, and software** out of the `BYOD staging` fleet unless needed for Interlude. This keeps them from queueing work before Interlude runs.

7. Once a host passes the **macOS - BYOD Interlude verified** policy it can be moved to your production fleet.

> *Optional*: Use Tines or another automation platform to [automatically transfer verified hosts to your production fleet](https://fleetdm.com/docs/rest-api/rest-api#update-hosts-fleet) and surface notifications/errors into Slack.

