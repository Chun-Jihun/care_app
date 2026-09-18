"""Allowlisted public MFDS services; no patient context or clinical decisions."""
from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import unquote, urlencode, urlsplit

from scripts.fetch_mfds_easy_drug import ConfigurationError


@dataclass(frozen=True)
class Service:
    title: str
    dataset_id: str
    env_prefix: str
    base_path: str
    operations: tuple[str, ...]

    @property
    def endpoint(self) -> str:
        return f"https://apis.data.go.kr{self.base_path}"

    @property
    def catalog_url(self) -> str:
        return f"https://www.data.go.kr/data/{self.dataset_id}/openapi.do"


SERVICES = {
    "permits": Service(
        "식품의약품안전처_의약품 제품 허가정보", "15095677", "GETDRUG",
        "/1471000/DrugPrdtPrmsnInfoService07",
        ("getDrugPrdtPrmsnInq07", "getDrugPrdtPrmsnDtlInq06", "getDrugPrdtMcpnDtlInq07"),
    ),
    "dur": Service(
        "식품의약품안전처_의약품안전사용서비스(DUR)품목정보", "15059486", "DUR",
        "/1471000/DURPrdlstInfoService03",
        ("getDurPrdlstInfoList03", "getOdsnAtentInfoList03",
         "getSpcifyAgrdeTabooInfoList03", "getCpctyAtentInfoList03",
         "getMdctnPdAtentInfoList03", "getEfcyDplctInfoList03",
         "getSeobangjeongPartitnAtentInfoList03", "getPwnmTabooInfoList03",
         "getUsjntTabooInfoList03"),
    ),
}

UNREVIEWED = {
    "approval_state": "staged_unreviewed",
    "clinical_review_completed": False,
    "runtime_rag_eligible": False,
    "mobile_bundle": False,
    "do_not_train": True,
}


def normalize_base(value: str, service: Service) -> str:
    """Accept the service base or one of its operations, never arbitrary URLs."""
    try:
        p = urlsplit(value.strip().rstrip("/"))
        valid = (
            p.scheme == "https" and p.hostname == "apis.data.go.kr"
            and p.port is None and not p.username and not p.password
            and not p.query and not p.fragment
            and p.path in {service.base_path, *(
                f"{service.base_path}/{op}" for op in service.operations
            )}
        )
    except ValueError:
        valid = False
    if not valid:
        raise ConfigurationError("공식 식약처 HTTPS 서비스 주소만 허용합니다.")
    return service.endpoint


def build_url(endpoint: str, service_key: str, *, page_no: int,
              num_rows: int, filters: dict) -> str:
    allowed = {
        f"{s.endpoint}/{op}" for s in SERVICES.values() for op in s.operations
    }
    if endpoint not in allowed or filters:
        raise ConfigurationError("허용된 공개 데이터 전체 수집 요청이 아닙니다.")
    if not service_key.strip() or page_no < 1 or not 1 <= num_rows <= 500:
        raise ConfigurationError("키·페이지 또는 페이지 크기(1~500)가 잘못되었습니다.")
    params = {"serviceKey": unquote(service_key.strip()), "pageNo": page_no,
              "numOfRows": num_rows, "type": "json"}
    return f"{endpoint}?{urlencode(params)}"
