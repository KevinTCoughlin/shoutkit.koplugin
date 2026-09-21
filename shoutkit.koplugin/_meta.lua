local _ = require("gettext")
-- No `name` field: PluginLoader derives it from the directory and warns that a
-- `name` in _meta.lua "is deprecated and will be ignored".
return {
    fullname = _("Radio"),
    description = _([[Browse and play internet radio stations from the Radio-Browser directory.]]),
}
