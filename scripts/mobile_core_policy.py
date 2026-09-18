"""Explicit build scope, not a clinical approval or a complete medical catalog."""

CORE_DOCUMENTS = frozenset({
    "dry-mouth-and-older-adults.pdf", "flossing-info-for-caregivers.pdf", "oral-health-aging-brushing.pdf",
    "steadi-brochure-checkforsafety-508.pdf", "steadi-caregiverbrochure.pdf",
    "Strat4_Tool_2a_IDEAL_Checklist_508.pdf", "Strat4_Tool_2b_IDEAL_Booklet_508.pdf",
    "Getting Started With Caregiving _ National Institute on Aging.html",
    "Sharing Caregiving Responsibilities _ National Institute on Aging.html",
    "How to help someone you care for keep clean - Care and support guide - NHS.html",
    "How to move, lift and handle someone else - Social care and support guide - NHS.html",
    "How to support someone you care for with eating - Social care and support guide - NHS.html",
    "Medicines_ tips for carers - Social care and support guide - NHS.html",
})

PERMIT_BASIC = "getDrugPrdtPrmsnInq07"
PERMIT_KEEP = frozenset({"ITEM_SEQ", "ITEM_NAME", "ITEM_ENG_NAME", "ENTP_NAME", "ITEM_INGR_NAME",
                         "ITEM_INGR_CNT", "SPCLTY_PBLC", "PRDUCT_TYPE", "CANCEL_NAME", "CANCEL_DATE", "ITEM_PERMIT_DATE"})
PERMIT_DROP = frozenset({"BIG_PRDT_IMG_URL", "BIZRNO", "EDI_CODE", "ENTP_ENG_NAME", "ENTP_NO",
                         "ENTP_SEQ", "INDUTY", "PERMIT_KIND_CODE", "PRDLST_STDR_CODE", "PRDUCT_PRMISN_NO"})

CORE_SCOPE = {
    "profile": "caregiver_essentials_v2",
    "prescription_details_included": False,
    "ingredient_quantity_records_included": False,
    "dur_scope": "all_downloaded_rows_and_fields",
    "empty_lookup_means_safe": False,
    "max_total_bytes": 50 * 1024 * 1024,
}

NOTICES = {
    "permits": "약 식별용 목록입니다. 전체 허가 상세·성분별 함량·처방약 효능/용법/주의사항은 이 기본 패키지에 없습니다.",
    "dur": "수집한 DUR 전체 관계와 조건을 포함합니다. 미검수 자료이며 조회 결과가 없어도 병용 가능·안전을 뜻하지 않습니다.",
    "easy-drug": "e약은요 수집 품목의 원문입니다. 포함되지 않은 약의 효능·주의사항은 확인할 수 없습니다.",
    "documents": "보호자용 문서 13종을 포함합니다. 659쪽 간호조무사 교재와 그 근거는 기본 자료에서 제외했습니다.",
}
