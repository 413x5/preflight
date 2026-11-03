"""Unwrap a provider's chat-completion envelope, inside pr-agent's own interpreter.

An endpoint may answer a NON-streaming chat completion wrapped in an envelope:

    {"data": {"choices": [...], "usage": {...}, ...}, "success": true}

LiteLLM looks for a top-level ``choices``, finds ``None`` and raises "provider returned 'choices' that is
not a list". Its streaming path is bare SSE, so the two disagree - and the streaming workaround
(``stream = true``) costs pr-agent every ``reasoning_content`` delta and loses the whole call on a
mid-stream cut.

This module patches ONE seam: ``openai._base_client.BaseClient._process_response_data``, the parse funnel
every OpenAI SDK response passes through. The wrapper swaps ``data`` for the wrapped body when the reply is
an envelope and the client's base URL is one the renderer armed; everything else is handed to the original
method unchanged, so a flat body is parsed exactly as before and nothing is re-validated or re-sent.

It is installed by ``install.sh`` as a ``.pth`` line in the tool venv's site-packages, which is how it
reaches pr-agent with no change to pr-agent:

    preflight_envelope.py       this file
    preflight_envelope.pth      one line: import preflight_envelope; preflight_envelope.install()

The line must begin with ``import``: ``site.py`` executes a line that does not (and evals one that does),
so a wrong line is silently ignored - a patch that is installed and does nothing.

Mechanism and the reason for this seam: docs/architecture.md. Requirement: REQ-HOOK-54.
"""

import os

# The settings section the renderer derives from a provider's `envelope` key. Absent means no endpoint is
# armed, and install() returns without touching anything.
SECTION = "preflight_envelope"
# The environment channel from the preflight helper to this module: the rendered config THIS run is using.
# Read here rather than by scanning the config dir, because a directory may hold several runs' files and a
# previous run's hosts must not arm this one.
CONFIG_ENV = "PREFLIGHT_ENVELOPE_CONFIG"
# The private SDK method. Private by convention, so install() verifies it is there and callable before
# patching, and refuses loudly if it is not - a patch that no-ops is the failure this feature exists for.
SEAM = "_process_response_data"
_SEAM_OWNER = ("openai._base_client", "BaseClient")
_DONE = "_preflight_envelope_installed"


def read_config(path):
    """Return (key, [hosts]) from a rendered config, or None when it does not arm the envelope.

    ``tomllib`` is stdlib from 3.11, and the tool venv this runs in is newer than that. A missing or
    unreadable file, a section that is not a table, an empty key or an empty host list all mean "not
    armed": the renderer only writes this section when a provider set `envelope`, so anything less is a
    configuration this module has no instruction for and must leave alone.
    """
    try:
        import tomllib
    except ModuleNotFoundError:  # pragma: no cover - the tool venv is 3.11+
        return None
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except (OSError, ValueError):
        return None
    section = data.get(SECTION)
    if not isinstance(section, dict):
        return None
    key = section.get("key")
    hosts = section.get("hosts")
    if not isinstance(key, str) or not key:
        return None
    if not isinstance(hosts, list) or not all(isinstance(h, str) and h for h in hosts):
        return None
    return key, [h.lower() for h in hosts]


def is_armed(body, key):
    """True when ``body`` is an envelope under ``key`` that should be unwrapped.

    The whole decision, so it is testable on its own. ``key`` is the configured top-level name, read from
    the rendered config rather than assumed: a hard-coded "data" would silently ignore every other value
    the renderer accepts.
    """
    if not isinstance(body, dict):
        return False
    # A body with a top-level choices list is a flat reply. Leaving it untouched is what keeps a provider
    # that occasionally answers both ways (bare and wrapped) working without a second knob.
    if isinstance(body.get("choices"), list):
        return False
    inner = body.get(key)
    return isinstance(inner, dict) and isinstance(inner.get("choices"), list)


def _host_matches(base_url, hosts):
    # The AUTHORITY is compared, not the whole URL: the configured value is host[:port] as the renderer
    # took it from api_base, while base_url carries a scheme and usually a path. Equality on the authority
    # rather than a substring is what stops an armed `api.env.test` from also arming `api.env.test.evil` -
    # a host nobody configured, whose envelope would then be rewritten on its behalf.
    authority = str(base_url).split("://", 1)[-1].split("/", 1)[0].rpartition("@")[2]
    return authority.lower() in hosts


def _install_seam(key, hosts):
    """Patch the SDK parse funnel. Returns the patched class."""
    import importlib

    module_name, attribute = _SEAM_OWNER
    module = importlib.import_module(module_name)
    seam_owner = getattr(module, attribute, None)
    patch = getattr(seam_owner, SEAM, None)
    if seam_owner is None or not callable(patch):
        raise LookupError(
            f"{module_name}.{attribute}.{SEAM} is missing or not callable; the OpenAI SDK this pr-agent "
            f"uses does not expose the response parse funnel the envelope shim patches"
        )
    if getattr(seam_owner, _DONE, False):
        return seam_owner

    original = patch

    def wrapped(self, *args, **kwargs):
        try:
            body = kwargs.get("data") if "data" in kwargs else args[0]
            if _host_matches(getattr(self, "base_url", ""), hosts) and is_armed(body, key):
                inner = body[key]
                if "data" in kwargs:
                    kwargs["data"] = inner
                else:
                    args = (inner,) + args[1:]
                # `cast_to` is NOT replaced: it is already the chat-completion model for this request, so
                # keeping it means the wrapped body is parsed by the same code path a flat one takes.
        except Exception:  # noqa: BLE001 - a shim never turns a parse into a new failure
            pass
        return original(self, *args, **kwargs)

    wrapped.__name__ = getattr(original, "__name__", SEAM)
    wrapped.__doc__ = getattr(original, "__doc__", None)
    wrapped.__wrapped__ = original
    setattr(seam_owner, SEAM, wrapped)
    setattr(seam_owner, _DONE, True)
    return seam_owner


def install(idx=None, system=None):
    """Entry point for the ``.pth`` line. Inert unless the run armed an endpoint.

    Raises SystemExit deliberately when the configuration asks for the shim and the seam is gone:
    ``site.py`` catches every Exception raised from a ``.pth`` line, prints it and carries on, so anything
    else would leave pr-agent running unwrapped - exactly the silent no-op this module exists to prevent.
    SystemExit is a BaseException and is not caught.
    """
    path = os.environ.get(CONFIG_ENV, "")
    if not path:
        return None
    armed = read_config(path)
    if armed is None:
        return None
    key, hosts = armed
    try:
        return _install_seam(key, hosts)
    except Exception as exc:  # noqa: BLE001 - re-raised as SystemExit, the only status site.py keeps
        import sys

        sys.stderr.write(
            f"preflight: the envelope shim cannot be applied to this pr-agent's OpenAI SDK ({exc}).\n"
            f"preflight: {CONFIG_ENV} arms {', '.join(hosts)}, so a review would read the wrapped reply as "
            f"an empty one.\n"
            f"preflight: re-run install.sh (it re-applies the patch), or remove that provider's 'envelope' "
            f"key to review without the workaround.\n"
        )
        raise SystemExit(2)


def selftest():
    """Report what install.sh and the gate need to know, without touching anything.

    ``seam`` is the property that cannot be checked without the SDK installed; ``armed`` depends on
    whether the run carries a configuration. Both are returned so a caller can say which of the two it
    could not verify instead of reporting a bare pass.
    """
    import importlib

    try:
        module = importlib.import_module(_SEAM_OWNER[0])
        seam_owner = getattr(module, _SEAM_OWNER[1], None)
        seam = seam_owner is not None and callable(getattr(seam_owner, SEAM, None))
    except Exception:  # noqa: BLE001 - "cannot import the SDK" is the same answer as "no seam"
        seam = False
    armed = read_config(os.environ.get(CONFIG_ENV, "")) if os.environ.get(CONFIG_ENV) else None
    return {"seam": seam, "armed": armed is not None}


if __name__ == "__main__":  # a human or the gate running it directly
    import json
    import sys

    result = selftest()
    print(json.dumps(result))
    sys.exit(0 if result["seam"] else 1)
