from typing import List, Optional
from pydantic import BaseModel, Field


class PartUsed(BaseModel):
    part_name: str
    quantity: int
    unit_price: Optional[float] = None


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
    labor_rate: Optional[float] = None
    parts_used: Optional[List[PartUsed]] = None


class ShopLogoStatus(BaseModel):
    has_custom_logo: bool


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


class CheckoutSessionResponse(BaseModel):
    checkout_url: str


class BillingStatusResponse(BaseModel):
    scope_type: str
    status: Optional[str] = None
    is_active: bool
    current_period_end: Optional[str] = None
    seat_limit: Optional[int] = None
    seat_used: Optional[int] = None


class OrganizationCreateRequest(BaseModel):
    name: str
    seat_limit: int


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
