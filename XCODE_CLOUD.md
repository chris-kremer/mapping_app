# Xcode Cloud

Run Map's continuous delivery workflow is managed in App Store Connect.

- Workflow: `Run Map Main TestFlight`
- Trigger: file changes pushed to `main`
- Build action: archive the `Run_Map` iOS scheme
- Distribution: internal TestFlight via the `Xcode Cloud - Main` group
