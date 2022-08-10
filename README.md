# millheat.lua

Lua interface to the [Millheat API](https://api.millheat.com/share/apidocument).
Please checkout [the documentation](https://tieske.github.io/millheat.lua/) for
instructions.

Works with plain LuaSocket/LuaSec, as well as with the Copas scheduler. Supports
LuaLogging for log output if available.

## Status

Early development, session management works, all basic methods implemented. The
newer control endpoints can be used, but do not have their own functions yet.

### TODO:

- implement newer control endpoints
- maybe: add a higher level Lua interface with object based access

## License & Copyright

See [LICENSE](https://github.com/Tieske/millheat.lua/blob/master/LICENSE)

## History

### Release instructions:

* update the version number and copyright year (ldoc header in `init.lua`)
* update copyright years in `LICENSE` file)
* ensure changelog is up-to-date
* add a rockspec for the new version
* render the docs using `ldoc`
* commit, tag, and push

### Version 0.1, released 10-Aug-2022

* initial release
