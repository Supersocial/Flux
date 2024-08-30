# Flux

You can install this package on Wally
```toml
Flux = "supersocial/flux@0.0.2"
```

## About
This is still a massive work-in-progress. There will almost certinaly be changes that are not backwards compatible, documentation will not be created until we get a solid V1, etc.
 
Flux is a Knit variant with some added functionality:
- You can now do `GetService` and `GetController` at the top of modules
- Components are an integrated part of the framework.
  - This allows you to do things like `Flux.GetComponent` at the top of modules as adding useful methods such as `Flux.GetComponentFromInstanceAndTag`.
  - Added a `_Trove` to all Components which are cleaned up when the Component is removed.
  - Added an `Activate` method to components so they don't run until Flux is started.
- Added multiple new lifecycle methods
  - Services
    - Service:FluxPlayerAdded(player: Player)
    - Service:FluxPlayerRemoving(player: Player)
    - Service:FluxHeartbeat(deltaTime: number)
    - ...
  - Controllers
   - ...
