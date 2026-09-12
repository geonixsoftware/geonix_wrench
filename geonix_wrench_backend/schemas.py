from typing import List, Optional
from pydantic import BaseModel, Field


class PartUsed(BaseModel):
    part_name: str
    # Fractional, because fluids are the parts this most often describes: half a
    # litre of coolant is a real line on a real job card, and an int quantity
    # could only round it to nothing or to double. Existing rows hold whole
    # numbers and still read back cleanly.
    # Zero or more, like every money and quantity field here: a negative line
    # is not a discount mechanism, it is a way to print an invoice with a
    # subtotal below zero.
    quantity: float = Field(ge=0)
    # Two ways to price a line, and `total_price` wins where both are set. See
    # pricing.line_total — a stated total is billed as stated rather than being
    # rebuilt from a rounded per-unit figure.
    unit_price: Optional[float] = Field(default=None, ge=0)
    total_price: Optional[float] = Field(default=None, ge=0)


class JobCardExtraction(BaseModel):
    vehicle_info: str
    labor_hours: float
    work_performed: str
    parts_used: List[PartUsed] = Field(default_factory=list)
    unbilled_items_flagged: List[str] = Field(default_factory=list)


class ProcessAudioResponse(BaseModel):
    transcript: str
    extraction: JobCardExtraction
    jobcard_id: int


class JobCardResponse(BaseModel):
    id: int
    created_at: str
    vehicle_info: str
    labor_hours: float
    labor_rate: Optional[float] = None
    work_performed: str
    parts_used: List[PartUsed]
    unbilled_items_flagged: List[str]
    transcript: str

    class Config:
        from_attributes = True


class JobCardUpdate(BaseModel):
    labor_rate: Optional[float] = Field(default=None, ge=0)
    parts_used: Optional[List[PartUsed]] = None


class ShopLogoStatus(BaseModel):
    has_custom_logo: bool
    # Whether the caller is allowed to replace or remove it. The app hides its
    # upload controls on this rather than re-deriving the rule from org_role,
    # so the permission is defined in exactly one place.
    can_manage: bool = True


class UserProfile(BaseModel):
    id: int
    email: str
    handle: Optional[str] = None
    display_name: Optional[str] = None
    org_id: Optional[int] = None
    org_role: Optional[str] = None


class HandleClaimRequest(BaseModel):
    handle: str


class OrganizationResponse(BaseModel):
    id: int
    name: str
    seat_limit: int
    seat_used: int
    owner_user_id: int
    subscription_status: Optional[str] = None
    current_period_end: Optional[str] = None


class CheckoutSessionRequest(BaseModel):
    plan: str
    quantity: Optional[int] = None
    success_url: str
    cancel_url: str
    # ISO 3166-1 alpha-2 country from the device locale. Picks the pricing
    # region (see regions.py); absent on older clients, which get the baseline.
    country: Optional[str] = None


class CheckoutSessionResponse(BaseModel):
    checkout_url: str


class BillingStatusResponse(BaseModel):
    scope_type: str
    status: Optional[str] = None
    is_active: bool
    current_period_end: Optional[str] = None
    seat_limit: Optional[int] = None
    seat_used: Optional[int] = None
    plan: Optional[str] = None
    min_seats: Optional[int] = None
    # The Team seat floor, quoted in every scope so the plan picker's stepper
    # is correct even for a caller who is not on the Team plan.
    team_min_seats: Optional[int] = None
    # Advertised price for the plan that matches this scope. Kept for existing
    # clients; new clients read the two plan-specific fields below instead.
    price_per_seat: Optional[float] = None
    # Both advertised prices, independent of the caller's current scope. The
    # plan picker shows Individual and Team side by side, so quoting only the
    # scope's own price made the *other* card advertise the wrong figure.
    individual_price: Optional[float] = None
    team_price_per_seat: Optional[float] = None
    # The pricing region the advertised figures above came from — the effective
    # one after any fallback, not necessarily what the caller's country implies.
    region: Optional[str] = None
    currency: Optional[str] = None
    can_manage_seats: bool = False
    # True when an active Team subscription is still waiting for its shop to be
    # named. The app prompts for a name only — the seat count is already paid.
    needs_shop: bool = False
    # How many devices this plan and role allow, and how many are signed in
    # now. Quoted alongside the plan so the subscription panel can state the
    # quota without re-deriving the rule from org_role — the mistake that would
    # let the app say "3 devices" to an employee entitled to one.
    device_limit: Optional[int] = None
    device_used: Optional[int] = None


class PortalSessionRequest(BaseModel):
    return_url: str


class PortalSessionResponse(BaseModel):
    portal_url: str


class SeatUpdateRequest(BaseModel):
    quantity: int = Field(ge=1)
    # Same as CheckoutSessionRequest.country: keeps the regional prices on the
    # status this call returns, which feeds the seat manager's total row.
    country: Optional[str] = None


class OrganizationCreateRequest(BaseModel):
    name: str
    # No seat_limit: the shop gets exactly the seats its owner paid for, read
    # from the Team subscription server-side. Accepting one from the client let
    # a shop be created with more seats than were purchased. Older clients may
    # still send the field; it is ignored rather than rejected.
    model_config = {"extra": "ignore"}


class MemberResponse(BaseModel):
    id: int
    handle: Optional[str] = None
    display_name: Optional[str] = None
    org_role: str


class InviteCreateRequest(BaseModel):
    handle: str


class InviteResponse(BaseModel):
    id: int
    org_id: int
    org_name: str
    invited_by_handle: Optional[str] = None
    status: str
    created_at: str


class DeviceSessionResponse(BaseModel):
    """One signed-in device, as the Settings list shows it.

    No device id, hashed or otherwise. The list is there so a user can point at
    a row and say "not that one" — the row id is enough to revoke it, and
    handing every client a stable per-install identifier for each of the user's
    devices would be giving out more than the screen needs.
    """

    id: int
    device_name: Optional[str] = None
    platform: Optional[str] = None
    created_at: str
    last_seen_at: str
    # True for the device asking. The app marks it "This device" and does not
    # offer a sign-out button on it, since that would end the session the user
    # is currently in from a screen that looks like housekeeping.
    is_current: bool = False


class DeviceSessionListResponse(BaseModel):
    devices: List[DeviceSessionResponse]
    # The quota and its use, so the screen never has to count the list itself —
    # `used` counts sessions, and a client that inferred it from `len(devices)`
    # would be right only until the list is ever paginated or filtered.
    limit: int
    used: int


class DeviceRegisterRequest(BaseModel):
    """Sent once per sign-in. The id also travels as a header on every request.

    The header is what enforcement reads; this body exists to carry the display
    name and platform, and to be the one call that can bring a previously
    signed-out device back — a background request must not be able to do that,
    or eviction would undo itself.
    """

    device_id: str = Field(min_length=1, max_length=200)
    device_name: Optional[str] = Field(default=None, max_length=200)
    platform: Optional[str] = Field(default=None, max_length=32)


class DeviceRegisterResponse(BaseModel):
    device: DeviceSessionResponse
    limit: int
    used: int
    # How many other devices this sign-in signed out to make room. The app
    # tells the user, because otherwise their tablet stops working across the
    # shop with no explanation attached to anything they did.
    evicted: int = 0
