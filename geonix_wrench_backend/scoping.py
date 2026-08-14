from typing import NamedTuple, Optional


class OwnerScope(NamedTuple):
    org_id: Optional[int]
    user_id: int


def resolve_owner_scope(user: dict) -> OwnerScope:
    return OwnerScope(org_id=user["org_id"], user_id=user["id"])
