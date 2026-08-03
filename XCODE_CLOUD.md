# Xcode Cloud

Run Map's continuous delivery workflow is managed in App Store Connect.

- Workflow: `Run Map Main TestFlight`
- Workflow ID: `E4C1D269-B706-443B-82E7-DA98B175F5B1`
- Source: GitHub repository `chris-kremer/mapping_app`
- Repository access: Xcode Cloud GitHub App
- Trigger: file changes pushed to `main`
- Recovery trigger: manual builds from `main`
- Build action: archive the `Run_Map` iOS scheme
- Distribution: internal TestFlight via the `Xcode Cloud - Main` group

The existing `Default` TrackerDashboard workflow is maintained separately and must remain intact.
