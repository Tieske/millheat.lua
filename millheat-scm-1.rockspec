package = "millheat"
version = "scm-1"

source = {
  url = "git://github.com/Tieske/millheat.lua",
  --tag = "0.1.0",
  branch = "master",
}

description = {
  summary = "Millheat API access for electrical heaters",
  detailed = [[
    Library to access the Millheat REST API.
  ]],
  homepage = "https://github.com/Tieske/millheat.lua",
  license = "MIT"
}

dependencies = {
  "lua >= 5.1, < 5.4",
  "luasec",
  "cjson",
}

build = {
  type = "builtin",
  modules = {
    ["millheat.init"] = "src/millheat/init.lua",
  },
}
