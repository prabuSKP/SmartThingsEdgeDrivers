# SmartThings Edge Driver AI Harness — Production Design

**Version:** 1.0  
**Framework Compatibility:** OpenClaw, AutoGen, LangGraph, CrewAI, custom agents  
**Status:** Production Blueprint

-----

## 1. Executive Summary

The SmartThings Edge Driver AI Harness is a workflow-first, state-machine-driven engineering system that transforms natural language device requests into fully validated, packaged SmartThings Edge Drivers. It is designed as a framework-agnostic harness layer — OpenClaw or any other open-source agent framework plugs in as the LLM orchestration backend.

### Core Design Principles

|Principle                      |Rationale                                            |
|-------------------------------|-----------------------------------------------------|
|Workflow-first, not agent-first|Deterministic state machines before autonomous agents|
|Knowledge-grounded generation  |SmartThings KB reduces LLM hallucination surface     |
|Resumable at every state       |Crash recovery, restart resilience                   |
|Validate-before-package        |4-layer validation before any packaging              |
|Audit every action             |Full trace for debugging and compliance              |
|Framework-agnostic interfaces  |LLM provider is a pluggable adapter                  |

-----

## 2. Repository Structure

```
smartthings-ai-harness/
├── harness/
│   ├── orchestrator/
│   │   ├── orchestrator.py          # Top-level workflow controller
│   │   ├── state_machine.py         # FSM engine
│   │   └── task_manager.py          # Task CRUD, retry logic
│   ├── modules/
│   │   ├── device_analyzer.py       # Protocol + category detection
│   │   ├── capability_mapper.py     # Vendor → SmartThings mapping
│   │   ├── profile_generator.py     # YAML profile builder
│   │   ├── presentation_generator.py# UI JSON builder
│   │   ├── lua_generator.py         # Lua driver code builder
│   │   ├── validator.py             # 4-layer validation
│   │   └── repair_engine.py         # Auto-fix failed artifacts
│   ├── knowledge/
│   │   ├── capabilities.json        # SmartThings capability catalog
│   │   ├── profiles.json            # Known profile patterns
│   │   ├── presentations.json       # UI presentation templates
│   │   ├── lan_patterns.json        # LAN driver patterns
│   │   ├── zigbee_patterns.json
│   │   ├── zwave_patterns.json
│   │   └── matter_patterns.json
│   ├── templates/
│   │   ├── lua/
│   │   │   ├── lan_base.lua.j2
│   │   │   ├── zigbee_base.lua.j2
│   │   │   ├── zwave_base.lua.j2
│   │   │   └── matter_base.lua.j2
│   │   ├── profile/
│   │   │   └── base_profile.yaml.j2
│   │   └── presentation/
│   │       └── base_presentation.json.j2
│   ├── adapters/
│   │   ├── llm_adapter.py           # Abstract LLM interface
│   │   ├── openclaw_adapter.py      # OpenClaw binding
│   │   ├── autogen_adapter.py       # AutoGen binding
│   │   └── langgraph_adapter.py     # LangGraph binding
│   ├── memory/
│   │   ├── memory_store.py
│   │   ├── generated_drivers/       # Successful driver cache
│   │   ├── capability_mappings/     # Resolved mappings cache
│   │   └── device_patterns/         # Device fingerprint cache
│   ├── storage/
│   │   ├── database.py              # SQLite/PostgreSQL abstraction
│   │   └── schema.sql
│   ├── cli/
│   │   ├── smartthings_cli.py       # ST CLI wrapper
│   │   └── packager.py              # Driver packaging
│   ├── observability/
│   │   ├── logger.py
│   │   ├── metrics.py
│   │   └── audit_trail.py
│   └── api/
│       ├── harness_api.py           # REST API for external agents
│       └── schemas.py               # Pydantic models
├── tests/
│   ├── unit/
│   ├── integration/
│   └── fixtures/
├── scripts/
│   └── deploy.sh
├── config/
│   └── harness_config.yaml
└── README.md
```

-----

## 3. Task Lifecycle & State Machine

### 3.1 Task States

```python
from enum import Enum

class DriverState(Enum):
    NEW                    = "NEW"
    ANALYZE_DEVICE         = "ANALYZE_DEVICE"
    MAP_CAPABILITIES       = "MAP_CAPABILITIES"
    GENERATE_PROFILE       = "GENERATE_PROFILE"
    GENERATE_PRESENTATION  = "GENERATE_PRESENTATION"
    GENERATE_DRIVER        = "GENERATE_DRIVER"
    VALIDATE               = "VALIDATE"
    REPAIR                 = "REPAIR"
    PACKAGE                = "PACKAGE"
    COMPLETE               = "COMPLETE"
    FAILED                 = "FAILED"
```

### 3.2 State Transition Table

|From State           |Trigger            |To State             |
|---------------------|-------------------|---------------------|
|NEW                  |start()            |ANALYZE_DEVICE       |
|ANALYZE_DEVICE       |success            |MAP_CAPABILITIES     |
|ANALYZE_DEVICE       |failure            |FAILED               |
|MAP_CAPABILITIES     |success            |GENERATE_PROFILE     |
|MAP_CAPABILITIES     |failure            |FAILED               |
|GENERATE_PROFILE     |success            |GENERATE_PRESENTATION|
|GENERATE_PRESENTATION|success            |GENERATE_DRIVER      |
|GENERATE_DRIVER      |success            |VALIDATE             |
|VALIDATE             |pass               |PACKAGE              |
|VALIDATE             |fail + retries_left|REPAIR               |
|VALIDATE             |fail + no retries  |FAILED               |
|REPAIR               |success            |VALIDATE             |
|REPAIR               |failure            |FAILED               |
|PACKAGE              |success            |COMPLETE             |
|PACKAGE              |failure            |FAILED               |

### 3.3 State Machine Implementation

```python
# harness/orchestrator/state_machine.py

class HarnessStateMachine:
    
    TRANSITIONS = {
        DriverState.NEW:                   [DriverState.ANALYZE_DEVICE],
        DriverState.ANALYZE_DEVICE:        [DriverState.MAP_CAPABILITIES, DriverState.FAILED],
        DriverState.MAP_CAPABILITIES:      [DriverState.GENERATE_PROFILE, DriverState.FAILED],
        DriverState.GENERATE_PROFILE:      [DriverState.GENERATE_PRESENTATION, DriverState.FAILED],
        DriverState.GENERATE_PRESENTATION: [DriverState.GENERATE_DRIVER, DriverState.FAILED],
        DriverState.GENERATE_DRIVER:       [DriverState.VALIDATE, DriverState.FAILED],
        DriverState.VALIDATE:              [DriverState.PACKAGE, DriverState.REPAIR, DriverState.FAILED],
        DriverState.REPAIR:                [DriverState.VALIDATE, DriverState.FAILED],
        DriverState.PACKAGE:               [DriverState.COMPLETE, DriverState.FAILED],
    }

    def transition(self, task: Task, target: DriverState) -> Task:
        allowed = self.TRANSITIONS.get(task.state, [])
        if target not in allowed:
            raise InvalidTransitionError(f"{task.state} -> {target} not allowed")
        task.state = target
        task.updated_at = datetime.utcnow().isoformat()
        self.persist(task)
        self.audit(task, target)
        return task
```

-----

## 4. Database Schema

```sql
-- Core task table
CREATE TABLE tasks (
    task_id       TEXT PRIMARY KEY,
    device_name   TEXT NOT NULL,
    state         TEXT NOT NULL DEFAULT 'NEW',
    status        TEXT NOT NULL DEFAULT 'PENDING',
    retry_count   INTEGER NOT NULL DEFAULT 0,
    max_retries   INTEGER NOT NULL DEFAULT 3,
    input_json    TEXT,        -- Original user request
    context_json  TEXT,        -- Accumulated context per state
    error_json    TEXT,        -- Last error details
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

-- Per-state artifact storage
CREATE TABLE artifacts (
    artifact_id   TEXT PRIMARY KEY,
    task_id       TEXT NOT NULL REFERENCES tasks(task_id),
    state         TEXT NOT NULL,
    artifact_type TEXT NOT NULL,  -- 'profile', 'presentation', 'driver', 'package'
    content       TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    created_at    TEXT NOT NULL
);

-- Audit trail
CREATE TABLE audit_log (
    log_id        TEXT PRIMARY KEY,
    task_id       TEXT NOT NULL,
    from_state    TEXT,
    to_state      TEXT NOT NULL,
    module        TEXT NOT NULL,
    action        TEXT NOT NULL,
    detail_json   TEXT,
    llm_tokens    INTEGER DEFAULT 0,
    duration_ms   INTEGER DEFAULT 0,
    timestamp     TEXT NOT NULL
);

-- Validation results
CREATE TABLE validation_results (
    result_id     TEXT PRIMARY KEY,
    task_id       TEXT NOT NULL,
    attempt       INTEGER NOT NULL,
    layer         INTEGER NOT NULL,  -- 1-4
    passed        INTEGER NOT NULL,  -- boolean
    errors_json   TEXT,
    timestamp     TEXT NOT NULL
);

-- Memory / pattern cache
CREATE TABLE memory_patterns (
    pattern_id    TEXT PRIMARY KEY,
    device_key    TEXT NOT NULL UNIQUE,
    protocol      TEXT NOT NULL,
    capabilities  TEXT NOT NULL,  -- JSON array
    profile_hash  TEXT NOT NULL,
    driver_hash   TEXT NOT NULL,
    use_count     INTEGER DEFAULT 1,
    last_used     TEXT NOT NULL
);
```

-----

## 5. LLM Adapter Interface (Framework-Agnostic)

```python
# harness/adapters/llm_adapter.py

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Optional, List

@dataclass
class LLMRequest:
    system_prompt: str
    user_prompt: str
    temperature: float = 0.1       # Low for deterministic generation
    max_tokens: int = 4096
    context_window: Optional[dict] = None  # Injected KB context

@dataclass
class LLMResponse:
    content: str
    tokens_used: int
    model: str
    latency_ms: int

class LLMAdapter(ABC):
    """Abstract interface. Implement for OpenClaw, AutoGen, LangGraph, etc."""

    @abstractmethod
    def complete(self, request: LLMRequest) -> LLMResponse:
        pass

    @abstractmethod
    def complete_structured(self, request: LLMRequest, schema: dict) -> dict:
        """Force structured JSON output."""
        pass

    @abstractmethod
    def health_check(self) -> bool:
        pass


# harness/adapters/openclaw_adapter.py
class OpenClawAdapter(LLMAdapter):
    def __init__(self, openclaw_client):
        self.client = openclaw_client

    def complete(self, request: LLMRequest) -> LLMResponse:
        # Translate to OpenClaw's native API
        result = self.client.chat(
            system=request.system_prompt,
            message=request.user_prompt,
            temperature=request.temperature,
        )
        return LLMResponse(
            content=result.text,
            tokens_used=result.usage.total_tokens,
            model=result.model,
            latency_ms=result.latency_ms,
        )

    def complete_structured(self, request: LLMRequest, schema: dict) -> dict:
        import json
        request.system_prompt += f"\n\nRespond ONLY with valid JSON matching: {json.dumps(schema)}"
        response = self.complete(request)
        return json.loads(response.content)

    def health_check(self) -> bool:
        try:
            r = self.complete(LLMRequest("ping", "respond with ok", max_tokens=10))
            return "ok" in r.content.lower()
        except:
            return False
```

-----

## 6. Module Specifications

### 6.1 Device Analyzer

**Input:** Raw device description string  
**Output:** Structured `DeviceContext`  
**LLM Usage:** Moderate (detect protocol, category, components)  
**KB Usage:** Protocol pattern lookup first; LLM only for ambiguous cases

```python
@dataclass
class DeviceContext:
    vendor: str
    model: str
    protocol: str           # LAN | Zigbee | ZWave | Matter | Cloud
    device_category: str    # switch | dimmer | sensor | lock | thermostat | ...
    components: List[str]   # ["main", "switch2"] for multi-component
    raw_features: List[str] # Vendor-reported feature list
    confidence: float       # 0.0 - 1.0

class DeviceAnalyzer:
    PROTOCOL_PATTERNS = {
        "lan": ["http", "rest", "ip", "local api", "fibaro", "hc3", "shelly"],
        "zigbee": ["zigbee", "zha", "ieee 802.15.4"],
        "zwave": ["z-wave", "zwave", "z wave"],
        "matter": ["matter", "thread", "chip"],
    }

    def analyze(self, device_description: str, task: Task) -> DeviceContext:
        # Step 1: KB lookup (no LLM)
        protocol = self._detect_protocol_from_kb(device_description)
        
        # Step 2: LLM for structured analysis
        if not protocol:
            protocol = self._detect_protocol_via_llm(device_description, task)
        
        context = self._build_context(device_description, protocol, task)
        self._persist_artifact(task, "device_context", context)
        return context
```

### 6.2 Capability Mapper

**Input:** `DeviceContext`  
**Output:** `CapabilityMap`  
**LLM Usage:** Minimal — deterministic KB lookup preferred  
**Key Rule:** No hallucinated capability IDs ever

```python
@dataclass
class CapabilityMap:
    capabilities: List[str]        # SmartThings capability IDs
    component_map: dict            # component_id -> [capabilities]
    custom_capabilities: List[str] # Flagged for manual review
    unmapped_features: List[str]   # Could not map

class CapabilityMapper:
    
    # Canonical mapping — single source of truth
    VENDOR_TO_ST = {
        "binary_switch":   "switch",
        "dimmer":          "switchLevel",
        "color_rgb":       "colorControl",
        "temperature":     "temperatureMeasurement",
        "humidity":        "relativeHumidityMeasurement",
        "motion":          "motionSensor",
        "contact":         "contactSensor",
        "lock":            "lock",
        "thermostat":      "thermostat",
        "energy_meter":    "energyMeter",
        "power_meter":     "powerMeter",
        "illuminance":     "illuminanceMeasurement",
        "battery":         "battery",
        "tamper":          "tamperAlert",
        "smoke":           "smokeDetector",
        "co":              "carbonMonoxideDetector",
    }
    
    ALWAYS_INCLUDE = ["refresh", "healthCheck"]
    
    def map(self, context: DeviceContext, task: Task) -> CapabilityMap:
        mapped = []
        unmapped = []
        
        for feature in context.raw_features:
            st_cap = self.VENDOR_TO_ST.get(feature.lower())
            if st_cap:
                mapped.append(st_cap)
            else:
                # LLM fallback with strict validation
                llm_result = self._llm_map_with_validation(feature, task)
                if llm_result and llm_result in self._get_valid_capability_ids():
                    mapped.append(llm_result)
                else:
                    unmapped.append(feature)
        
        mapped += self.ALWAYS_INCLUDE
        return CapabilityMap(
            capabilities=list(set(mapped)),
            component_map=self._build_component_map(context, mapped),
            custom_capabilities=[],
            unmapped_features=unmapped,
        )
```

### 6.3 Profile Generator

**Input:** `CapabilityMap` + `DeviceContext`  
**Output:** YAML profile string  
**LLM Usage:** None — pure template rendering

```python
# templates/lua/lan_base.lua.j2 excerpt
PROFILE_TEMPLATE = """
name: {{ device_name | lower | replace(' ', '-') }}

components:
{% for component in components %}
  - id: {{ component.id }}
    capabilities:
{% for cap in component.capabilities %}
      - id: {{ cap }}
        version: 1
{% endfor %}
{% endfor %}
"""

class ProfileGenerator:
    def generate(self, capability_map: CapabilityMap, context: DeviceContext, task: Task) -> str:
        template = self.jinja_env.get_template("base_profile.yaml.j2")
        profile_yaml = template.render(
            device_name=context.model,
            components=[
                {"id": comp, "capabilities": caps}
                for comp, caps in capability_map.component_map.items()
            ]
        )
        self._validate_yaml(profile_yaml)
        self._persist_artifact(task, "profile", profile_yaml)
        return profile_yaml
```

### 6.4 Lua Driver Generator

**Input:** `DeviceContext` + `CapabilityMap` + profile  
**Output:** Lua driver source (init.lua + supporting files)  
**LLM Usage:** High — generates protocol handlers and event logic  
**Template:** Pre-structured; LLM fills handler bodies only

```lua
-- templates/lua/lan_base.lua.j2

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

-- Capability handlers
{% for cap in capabilities %}
local function handle_{{ cap | replace('.', '_') }}(driver, device, command)
  -- LLM-GENERATED HANDLER BODY
  {{ handlers[cap] }}
end
{% endfor %}

-- Device lifecycle
local function device_added(driver, device)
  log.info("Device added: " .. device.label)
  device:online()
  {% for cap in capabilities %}
  device:emit_event(capabilities.{{ cap }}.{{ default_events[cap] }})
  {% endfor %}
end

local driver = Driver("{{ driver_name }}", {
  discovery = require "discovery",
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    removed = device_removed,
  },
  capability_handlers = {
    {% for cap in capabilities %}
    [capabilities.{{ cap }}] = {
      [capabilities.{{ cap }}.commands.{{ default_commands[cap] }}] = handle_{{ cap | replace('.', '_') }},
    },
    {% endfor %}
  },
})

driver:run()
```

-----

## 7. Validation Framework (4 Layers)

```python
@dataclass
class ValidationResult:
    passed: bool
    layer: int
    errors: List[str]
    warnings: List[str]

class Validator:

    def validate_all(self, task: Task, artifacts: dict) -> ValidationResult:
        for layer in [1, 2, 3, 4]:
            result = self._validate_layer(layer, task, artifacts)
            self._persist_result(task, layer, result)
            if not result.passed:
                return result
        return ValidationResult(passed=True, layer=4, errors=[], warnings=[])

    def _validate_layer(self, layer: int, task: Task, artifacts: dict) -> ValidationResult:
        if layer == 1:
            return self._validate_structure(artifacts)
        elif layer == 2:
            return self._validate_capabilities(artifacts)
        elif layer == 3:
            return self._validate_syntax(artifacts)
        elif layer == 4:
            return self._validate_packaging(artifacts)

    def _validate_structure(self, artifacts: dict) -> ValidationResult:
        """Layer 1: All required files present."""
        required = ["profile.yaml", "presentation.json", "init.lua", "fingerprints.yaml"]
        missing = [f for f in required if f not in artifacts]
        return ValidationResult(
            passed=len(missing) == 0,
            layer=1,
            errors=[f"Missing artifact: {f}" for f in missing],
            warnings=[],
        )

    def _validate_capabilities(self, artifacts: dict) -> ValidationResult:
        """Layer 2: Capability IDs consistent across profile and driver."""
        profile_caps = self._extract_profile_capabilities(artifacts["profile.yaml"])
        driver_caps = self._extract_driver_capabilities(artifacts["init.lua"])
        missing_in_driver = profile_caps - driver_caps
        extra_in_driver = driver_caps - profile_caps
        errors = []
        if missing_in_driver:
            errors.append(f"Capabilities in profile but not in driver: {missing_in_driver}")
        if extra_in_driver:
            errors.append(f"Capabilities in driver not in profile: {extra_in_driver}")
        return ValidationResult(passed=len(errors) == 0, layer=2, errors=errors, warnings=[])

    def _validate_syntax(self, artifacts: dict) -> ValidationResult:
        """Layer 3: Lua syntax, YAML validity, JSON validity."""
        errors = []
        errors += self._check_lua_syntax(artifacts.get("init.lua", ""))
        errors += self._check_yaml_syntax(artifacts.get("profile.yaml", ""))
        errors += self._check_json_syntax(artifacts.get("presentation.json", ""))
        return ValidationResult(passed=len(errors) == 0, layer=3, errors=errors, warnings=[])

    def _validate_packaging(self, artifacts: dict) -> ValidationResult:
        """Layer 4: smartthings edge:drivers:package must succeed."""
        import subprocess
        result = subprocess.run(
            ["smartthings", "edge:drivers:package", artifacts["package_dir"]],
            capture_output=True, text=True, timeout=60
        )
        return ValidationResult(
            passed=result.returncode == 0,
            layer=4,
            errors=[result.stderr] if result.returncode != 0 else [],
            warnings=[],
        )
```

-----

## 8. Repair Engine

```python
class RepairEngine:
    
    REPAIR_STRATEGIES = {
        "missing_capability": "regenerate_profile",
        "capability_mismatch": "sync_driver_to_profile",
        "lua_syntax_error": "fix_lua_syntax",
        "yaml_syntax_error": "fix_yaml_syntax",
        "json_syntax_error": "fix_json_syntax",
        "packaging_error": "fix_package_structure",
    }

    def repair(self, task: Task, validation_result: ValidationResult, artifacts: dict) -> dict:
        if task.retry_count >= task.max_retries:
            raise MaxRetriesExceededError(task)
        
        task.retry_count += 1
        
        for error in validation_result.errors:
            strategy = self._classify_error(error)
            repair_fn = getattr(self, f"_repair_{strategy}", None)
            if repair_fn:
                artifacts = repair_fn(error, artifacts, task)
            else:
                # LLM-assisted repair as fallback
                artifacts = self._llm_repair(error, artifacts, task)
        
        return artifacts

    def _repair_capability_mismatch(self, error: str, artifacts: dict, task: Task) -> dict:
        """Sync driver capability handlers to match profile."""
        profile_caps = self._extract_profile_capabilities(artifacts["profile.yaml"])
        artifacts["init.lua"] = self._regenerate_driver_section(
            artifacts["init.lua"], profile_caps, task
        )
        return artifacts

    def _llm_repair(self, error: str, artifacts: dict, task: Task) -> dict:
        """General LLM-assisted repair with strict output constraints."""
        prompt = self._build_repair_prompt(error, artifacts)
        response = self.llm.complete_structured(
            LLMRequest(
                system_prompt=REPAIR_SYSTEM_PROMPT,
                user_prompt=prompt,
                temperature=0.0,  # Fully deterministic for repair
            ),
            schema=REPAIR_RESPONSE_SCHEMA,
        )
        return self._apply_repair_patch(response["patch"], artifacts)
```

-----

## 9. Memory System

```python
class MemoryStore:
    """
    Cache successful driver patterns to:
    - Reduce LLM calls by ~60% on known device families
    - Ensure consistency across similar devices
    - Speed up generation for repeat protocol patterns
    """

    def lookup(self, device_key: str) -> Optional[dict]:
        """Check if we have a cached pattern for this device type."""
        return self.db.query(
            "SELECT * FROM memory_patterns WHERE device_key = ?", [device_key]
        )

    def store(self, task: Task, artifacts: dict):
        """Cache a validated + packaged driver for future reuse."""
        device_key = self._compute_device_key(task)
        self.db.upsert("memory_patterns", {
            "pattern_id": str(uuid4()),
            "device_key": device_key,
            "protocol": task.context["protocol"],
            "capabilities": json.dumps(task.context["capabilities"]),
            "profile_hash": hashlib.sha256(artifacts["profile.yaml"].encode()).hexdigest(),
            "driver_hash": hashlib.sha256(artifacts["init.lua"].encode()).hexdigest(),
            "use_count": 1,
            "last_used": datetime.utcnow().isoformat(),
        })

    def _compute_device_key(self, task: Task) -> str:
        """Stable key based on protocol + capability fingerprint."""
        caps_sorted = sorted(task.context.get("capabilities", []))
        protocol = task.context.get("protocol", "unknown")
        return hashlib.md5(f"{protocol}:{':'.join(caps_sorted)}".encode()).hexdigest()
```

-----

## 10. Observability & Audit Trail

```python
# Every state transition, LLM call, and validation is logged
@dataclass
class AuditEvent:
    task_id: str
    from_state: Optional[str]
    to_state: str
    module: str
    action: str
    detail: dict
    llm_tokens: int
    duration_ms: int
    timestamp: str

class AuditTrail:
    def log(self, event: AuditEvent):
        self.db.insert("audit_log", asdict(event))
        self.metrics.record(event)
        self.logger.info(f"[{event.task_id}] {event.from_state} -> {event.to_state} | {event.action}")

# Metrics tracked
METRICS = [
    "task.total",
    "task.success_rate",
    "task.avg_duration_ms",
    "task.retry_rate",
    "llm.total_tokens",
    "llm.calls_per_task",
    "validation.layer_fail_rate",
    "memory.cache_hit_rate",
    "repair.success_rate",
]
```

-----

## 11. REST API (External Agent Integration)

```python
# harness/api/harness_api.py — FastAPI

from fastapi import FastAPI
app = FastAPI(title="SmartThings AI Harness API")

@app.post("/tasks")
async def create_task(request: CreateTaskRequest) -> TaskResponse:
    """Create a new driver generation task."""
    task = orchestrator.create_task(request.device_name, request.options)
    return TaskResponse(task_id=task.task_id, state=task.state)

@app.get("/tasks/{task_id}")
async def get_task(task_id: str) -> TaskDetailResponse:
    """Get full task status + artifact references."""
    return orchestrator.get_task(task_id)

@app.post("/tasks/{task_id}/resume")
async def resume_task(task_id: str) -> TaskResponse:
    """Resume a task from its last persisted state."""
    task = orchestrator.resume_task(task_id)
    return TaskResponse(task_id=task.task_id, state=task.state)

@app.get("/tasks/{task_id}/artifacts")
async def get_artifacts(task_id: str) -> ArtifactsResponse:
    """Download generated profile, presentation, driver."""
    return orchestrator.get_artifacts(task_id)

@app.get("/tasks/{task_id}/audit")
async def get_audit(task_id: str) -> AuditResponse:
    """Full audit trail for a task."""
    return audit_trail.get_task_events(task_id)

@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "llm": llm_adapter.health_check()}
```

-----

## 12. Security Model

|Concern                              |Mitigation                                    |
|-------------------------------------|----------------------------------------------|
|LLM prompt injection via device names|Input sanitization before all prompts         |
|Malicious Lua code generation        |Static analysis pass before packaging         |
|Credential exposure in logs          |All tokens/keys masked in audit trail         |
|CLI command injection                |Subprocess with arg lists, never shell=True   |
|Knowledge base tampering             |SHA-256 hash verification on load             |
|Artifact integrity                   |Content hash stored and verified at each state|

-----

## 13. Multi-Agent Evolution Path

Only activate after Harness V1 is stable (all 10 tasks complete without human intervention).

```
Phase 1 (Now):    Monolithic Harness + Single LLM
Phase 2 (Stable): Extract Validator Agent
Phase 3 (+agents): Capability Agent, Generator Agent
Phase 4 (Full):   Manager Agent orchestrates specialized agents

Manager Agent
      |
      ├── Docs Agent          (SmartThings docs retrieval)
      ├── Capability Agent    (deterministic KB + LLM)
      ├── Generator Agent     (profile + presentation + Lua)
      ├── Validator Agent     (4-layer validation)
      └── Repair Agent        (error analysis + fix)
```

Migration rule: **Never extract a module to an agent until that module has 100% unit test coverage.**

-----

## 14. Sprint Roadmap

|Sprint|Deliverables                                            |Exit Criteria                             |
|------|--------------------------------------------------------|------------------------------------------|
|1     |Task Manager, SQLite, State Machine                     |Tasks persist and resume across restarts  |
|2     |Device Analyzer, Capability Mapper, Knowledge Base      |Correct mapping for 10 test devices       |
|3     |Profile Generator, Presentation Generator, Lua Generator|Valid artifacts for 5 protocols           |
|4     |Validator (all 4 layers), Repair Engine                 |Auto-repair resolves >80% of failures     |
|5     |Packaging, Memory System, REST API                      |End-to-end: request → .zip in <5 min      |
|6     |Observability, Audit Trail, CI/CD                       |All metrics captured, GitHub Actions green|
|7     |Multi-agent extraction (Validator, then Capability)     |Agent swap is transparent to orchestrator |

-----

## 15. Definition of Done

The harness is production-ready when:

1. Given only a device name, it produces a valid, installable SmartThings Edge Driver package
1. All tasks are resumable after unexpected process termination
1. Retry/repair handles 80%+ of validation failures without human intervention
1. Full audit trail exists for every task
1. Memory cache reduces LLM token usage by 40%+ for repeat device families
1. REST API allows any agent framework to drive the harness
1. 90%+ unit test coverage on all modules
1. Zero hallucinated capability IDs in validated outputs

-----

*SmartThings AI Harness — Production Design v1.0*