# millheat.lua

Lua interface to the [Millheat API](https://api.millheat.com/share/apidocument).
Please checkout [the documentation](https://tieske.github.io/millheat.lua/) for
instructions.

Works with plain LuaSocket/LuaSec, as well as with the Copas scheduler. Supports
LuaLogging for log output if available.

## Status

Early development, session management works, all basic methods implemented.

### TODO

- maybe: add a higher level Lua interface with object based access

## License & Copyright

See [LICENSE](https://github.com/Tieske/millheat.lua/blob/master/LICENSE)

## History

### Release instructions

- update the version number and copyright year (ldoc header in `init.lua`)
- update copyright years in `LICENSE` file)
- ensure changelog is up-to-date
- add a rockspec for the new version
- render the docs using `ldoc`
- commit, tag, and push

### Version 0.4.1, released 11-Feb-2024

- fix: refresh access-token header parameter accidentally in query.

### Version 0.4.0, released 11-Feb-2024

- BREAKING: reimplement the core, based on the new REST API.

### Version 0.3.0, released 30-Dec-2022

- change: convert millheat specific internal errors to generic http response codes

### Version 0.2.0, released 22-Oct-2022

- fix: better error messages in case data elements are missing

### Version 0.1.0, released 10-Aug-2022

- initial release
