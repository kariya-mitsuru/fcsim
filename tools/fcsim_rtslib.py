"""
rtslib-fb support for the tcm_fcsim LIO fabric ("fcsim").

rtslib-fb keeps its list of fabrics in rtslib_fb.fabric.fabric_modules and
has no plugin mechanism, so register() injects the fabric before targetcli /
targetctl start.  WWNs are shown as naa.XXXXXXXXXXXXXXXX in targetcli and
stored as xx:xx:xx:xx:xx:xx:xx:xx in configfs, like qla2xxx.
"""

from rtslib_fb import fabric as _fabric
from rtslib_fb.utils import colonize


class FcsimFabricModule(_fabric._BaseFabricModule):
    def __init__(self):
        super(FcsimFabricModule, self).__init__('fcsim')
        self.features = ("acls",)
        self.wwn_types = ('naa',)
        self.kernel_module = "tcm_fcsim"

    def to_fabric_wwn(self, wwn):
        # naa.2100000000000001 -> 21:00:00:00:00:00:00:01
        return colonize(wwn[4:].lower())

    def from_fabric_wwn(self, wwn):
        return "naa." + wwn.replace(":", "")


def register():
    _fabric.fabric_modules.setdefault("fcsim", FcsimFabricModule)
