"""
Где лежат бинарники движков: рядом со скриптами (так их кладёт в .app
app/scripts/make_app.sh) или в engines/ репозитория после локальной сборки.
"""
import os
import shutil
from typing import Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Куда кладёт бинарник локальная сборка каждого движка.
_BUILT = {
    "ethvanity": os.path.join(REPO, "engines", "ethvanity", "target", "release", "ethvanity"),
    "metalvanity": os.path.join(REPO, "engines", "metalvanity", "build", "metalvanity"),
    "metalvanity-evm": os.path.join(REPO, "engines", "metalvanity-evm", "target", "release", "metalvanity-evm"),
}


def find(name: str) -> Optional[str]:
    """Путь к исполняемому файлу движка или None, если он не собран."""
    for path in (os.path.join(HERE, name), _BUILT[name]):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return shutil.which(name)
