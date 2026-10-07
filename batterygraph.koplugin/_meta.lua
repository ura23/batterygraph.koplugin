-- v1.0: localized metadata via batterygraph_i18n; fixed stray quote in description.
local tr = require("batterygraph_i18n").tr
return {
    fullname = tr("Battery graph", "Графік батареї"),
    description = tr("Shows a battery discharge/charge graph over time.",
                     "Відображає графік розряду та заряджання батареї в часі."),
}
