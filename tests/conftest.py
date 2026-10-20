import os

# Avant tout import de caisse.* : Settings est mis en cache au premier appel.
os.environ.setdefault("APP_ENV", "test")
os.environ.setdefault("JWT_SECRET", "test-secret-" + "x" * 40)
