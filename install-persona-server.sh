#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

echo "========================================================="
echo "  PrivateNess NVS Spec v1.0 + EmerDNS TLSA Engine        "
echo "            (Isolated Environment Deployment)            "
echo "========================================================="

# Environment validation
if ! command -v python3 &> /dev/null; then
    echo "[-] Error: Python3 missing from PATH environment."
    exit 1
fi

TARGET_DIR="$HOME/.emer-ai-tools/servers/ness-persona"
mkdir -p "$TARGET_DIR"

echo "[+] Initializing isolated Python Virtual Environment (venv)..."
python3 -m venv "$TARGET_DIR/venv"

echo "[+] Activating venv and upgrading core package managers..."
source "$TARGET_DIR/venv/bin/activate"
pip install --quiet --upgrade pip

echo "[+] Injecting isolated packages: mcp[cli], httplib2, cryptography..."
pip install --quiet mcp[cli] httplib2 cryptography

echo "[+] Deploying server binaries with native TLSA/DANE checking..."
cat << 'EOF' > "$TARGET_DIR/ness_persona_server.py"
import sys
import json
import socket
import ssl
import hashlib
import xml.etree.ElementTree as ET
import httplib2
from mcp.server.fastmcp import FastMCP
from cryptography import x509
from cryptography.hazmat.primitives import serialization

mcp = FastMCP("NESS-Persona-And-TLSA-Engine")
EMERCOIN_RPC_URL = "http://127.0.0.1:6662"
RPC_USER = "emercoinrpc"
RPC_PASSWORD = "your_actual_rpc_password"

def call_local_rpc(method, params):
    http = httplib2.Http()
    http.add_credentials(RPC_USER, RPC_PASSWORD)
    payload = {"version": "1.1", "method": method, "params": params, "id": 1}
    headers = {'Content-Type': 'application/json'}
    try:
        response, content = http.request(EMERCOIN_RPC_URL, "POST", body=json.dumps(payload), headers=headers)
        if response.status == 200:
            return json.loads(content.decode('utf-8')).get("result")
        return None
    except:
        return None

@mcp.tool()
def verify_node_tlsa_record(host: str, port: int, emer_dns_domain: str) -> str:
    missing = []
    if not host: missing.append("host")
    if not port: missing.append("port")
    if not emer_dns_domain: missing.append("emer_dns_domain")
    if missing: return json.dumps({"status": "INPUT_REQUIRED", "prompt_user_for": missing})
    try:
        dns_record = call_local_rpc("name_show", [f"dns:{emer_dns_domain}"])
        if not dns_record or "value" not in dns_record:
            return f"HARD FAIL: EmerDNS record 'dns:{emer_dns_domain}' not found."
        tlsa_line = None
        for line in dns_record["value"].split('\n'):
            if line.upper().startswith("TLSA="):
                tlsa_line = line.split("=", 1)[1].strip()
                break
        if not tlsa_line: return "HARD FAIL: No TLSA token configuration found in EmerDNS entry."
        parts = tlsa_line.split()
        usage, selector, matching_type = int(parts[0]), int(parts[1]), int(parts[2])
        onchain_association_data = "".join(parts[3:]).lower()
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, port), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=host) as ssock:
                der_cert = ssock.getpeercert(binary_form=True)
        cert = x509.load_der_x509_certificate(der_cert)
        target_bytes = der_cert if selector == 0 else cert.public_key().public_bytes(encoding=serialization.Encoding.DER, format=serialization.PublicFormat.SubjectPublicKeyInfo)
        if matching_type == 0: calculated_fingerprint = target_bytes.hex().lower()
        elif matching_type == 1: calculated_fingerprint = hashlib.sha256(target_bytes).hexdigest().lower()
        elif matching_type == 2: calculated_fingerprint = hashlib.sha512(target_bytes).hexdigest().lower()
        else: return "HARD FAIL: Unsupported TLSA matching rules."
        if calculated_fingerprint != onchain_association_data:
            return json.dumps({"status": "CRITICAL_SECURITY_BREACH", "message": "HARD FAIL: Fingerprint mismatch against EmerDNS TLSA baseline!"})
        return json.dumps({"status": "TRUST_ESTABLISHED", "domain_verified": emer_dns_domain})
    except Exception as e:
        return f"TLSA validation exception triggered: {str(e)}"

@mcp.tool()
def update_ness_persona(id_username: str, ipfs_hash: str, magnet_link: str, pubkey: str, skywire_pubkey: str = "", created_timestamp: str = "", anchor_block: str = "", days_valid: int = 365) -> str:
    missing_inputs = []
    if not id_username: missing_inputs.append("id_username")
    if not ipfs_hash: missing_inputs.append("ipfs_hash")
    if not magnet_link: missing_inputs.append("magnet_link")
    if not pubkey: missing_inputs.append("pubkey")
    if not created_timestamp: missing_inputs.append("created_timestamp")
    if not anchor_block: missing_inputs.append("anchor_block")
    if missing_inputs: return json.dumps({"status": "INPUT_REQUIRED", "prompt_user_for": missing_inputs})
    try:
        worm_root = ET.Element("worm", {"version": "1.0", "type": "id"})
        meta_elem = ET.SubElement(worm_root, "meta")
        ET.SubElement(meta_elem, "schema").text = "worm:id:1.0"
        ET.SubElement(meta_elem, "created").text = created_timestamp
        ET.SubElement(meta_elem, "anchor_block").text = str(anchor_block)
        id_elem = ET.SubElement(worm_root, "identity")
        ET.SubElement(id_elem, "nvs_key").text = f"id:{id_username}"
        id_elem.find("pubkey_algo").text = "Ed25519" if hasattr(id_elem.find("pubkey_algo"), "text") else ET.SubElement(id_elem, "pubkey_algo")
        id_elem.find("pubkey_algo").text = "Ed25519"
        ET.SubElement(id_elem, "pubkey").text = pubkey
        if skywire_pubkey: ET.SubElement(id_elem, "skywire_pubkey").text = skywire_pubkey
        node_elem = ET.SubElement(worm_root, "node", {"type": "ness", "url": f"http://ness.cx{ipfs_hash}", "network": "inet"})
        ET.SubElement(node_elem, "ipfs_cid").text = ipfs_hash
        ET.SubElement(node_elem, "magnet_uri").text = magnet_link
        worm_xml_payload = ET.tostring(worm_root, encoding='utf-8').decode('utf-8')
        nvs_key = f"id:{id_username}"
        rpc_result = call_local_rpc("name_new", [nvs_key, worm_xml_payload, days_valid])
        return json.dumps({"status": "SUCCESS", "nvs_key_written": nvs_key, "rpc_response": rpc_result}, indent=2)
    except Exception as ex: return f"XML encoding failure: {str(ex)}"

if __name__ == "__main__":
    mcp.run()
EOF

# 5. Integrate into active Claude Desktop configurations using the isolated executable path
CLAUDE_CONFIG_DIR="$HOME/.config/Claude"  # Adjusted default for Linux/Kali environments
mkdir -p "$CLAUDE_CONFIG_DIR"
CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

if [ ! -f "$CONFIG_FILE" ]; then echo '{"mcpServers":{}}' > "$CONFIG_FILE"; fi

python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f: data = json.load(f)
if 'mcpServers' not in data: data['mcpServers'] = {}
data['mcpServers']['ness-persona-engine'] = {
    'command': '$TARGET_DIR/venv/bin/python3',
    'args': ['$TARGET_DIR/ness_persona_server.py']
}
with open('$CONFIG_FILE', 'w') as f: json.dump(data, f, indent=2)
"

# Copy execution script locally to your project folder for quick execution tests
cat << EOF > ./run-server.sh
#!/usr/bin/env bash
$TARGET_DIR/venv/bin/python3 $TARGET_DIR/ness_persona_server.py
EOF
chmod +x ./run-server.sh

deactivate

echo "========================================================="
echo "[+] SUCCESS: Step 5 EmerDNS TLSA DANE Verification Live."
echo "[+] To run manually from terminal, type: ./run-server.sh"
echo "========================================================="
