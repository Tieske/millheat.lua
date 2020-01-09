# millheat.lua
Lua interface to the [Millheat API](https://api.millheat.com/share/apidocument).
Please checkout [the documentation](https://tieske.github.io/millheat.lua/) for
instructions.

## Status

# * WARNING * WARNING * WARNING * WARNING *

The API unfortunately uses an insecure and deprecated TLSv1 version. So use
at your own risk. This also applies to their apps, hence please make sure you
do not re-use any passwords, but create a unique one for this API.

See: https://github.com/Tieske/millheat.lua/pull/1

Once the problem is resolved:

 - update your unique password
 - re-request access tokens (here: https://api.millheat.com/ )

# * WARNING * WARNING * WARNING * WARNING *

Early development, session management works, all current methods implemented
(that said; there are not that many methods unfortunately).


### TODO:

- remove the insecure TLSv1 requirement!!
- maybe: ad a higher level Lua interface with object based access

## History

### Release instructions:

* make sure to update the version number in the code files
* add a rockspec for the new version
* render the docs using `ldoc`
* commit, tag, and push

### Version x.x, released xx-xx-202x

* initial release

## License & Copyright

See [LICENSE](https://github.com/Tieske/millheat.lua/blob/master/LICENSE)

