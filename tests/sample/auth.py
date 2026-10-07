"""Authentication guard for the sample app.

The integration tests treat this file as security-relevant: deleting it, renaming it away or
replacing it with a symlink must not be committable without a fresh review.
"""


def require_token(token):
    if not token:
        raise PermissionError("a token is required")
    return True
