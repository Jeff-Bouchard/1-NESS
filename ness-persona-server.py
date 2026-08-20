import sys
import json
import socket
import ssl
import hashlib
import xml.etree.ElementTree as ET
import httplib2
from mcp import FastMCP
from cryptography import x509
from cryptography.hazmat.primitives import serialization

mcp = FastMCP("NESS-Persona-And-TLSA-Engine")

EMERCOIN_RPC_URL = "http://127.0.0.1:6662"
RPC_USER = "emercoinrpc"
RPC_PASSWORD = "your_actual_rpc_password"

def call_local_rpc(method, params):
    """Sub-second loopback JSON-RPC call straight to the full node over 127.0.0.1."""
    http = httplib2.Http()
    http.add_credentials(RPC_USER, RPC_PASSWORD)
    payload = {"version": "1.1", "method": method, "params": params, "id": 1}
    headers = {'Content-Type': 'application/json'}
    try:
        response, content = http.request(EMERCOIN_RPC_URL, "POST", body=json.dumps(payload), headers=headers)
        if response.status == 200:
            return json.loads(content.decode('utf-8')).get("result")
        return None
    except Exception:
        return None

@mcp.tool()
def verify_node_tlsa_record(host: str, port: int, emer_dns_domain: str) -> str:
    """
    Executes Step 5 of the PrivateNess Discovery Flow using decentralized DANE / TLSA.
    Fetches the live TLS cert, retrieves the TLSA record from EmerDNS (NVS),
    and forces a hard failure if the cert fingerprint doesn't match the on-chain TLSA anchor.
    """
    # 1. Input check - prompt user if anything is missing
    missing = []
    if not host: missing.append("host")
    if not port: missing.append("port")
    if not emer_dns_domain: missing.append("emer_dns_domain (e.g., 'node.bazar')")
    if missing:
        return json.dumps({"status": "INPUT_REQUIRED", "prompt_user_for": missing})

    try:
        # 2. Fetch the TLSA record from the local Emercoin node via EmerDNS NVS
        # EmerDNS handles DNS configuration inside NVS under keys like "dns:node.bazar"
        dns_record = call_local_rpc("name_show", [f"dns:{emer_dns_domain}"])
        if not dns_record or "value" not in dns_record:
            return f"HARD FAIL: EmerDNS record 'dns:{emer_dns_domain}' not found on-chain. Trust anchor missing. Aborting."

        # Parse the EmerDNS configuration to locate the TLSA field
        # Standard configuration layout usually matches: TLSA=usage selector matching_type data
        dns_value = dns_record["value"]
        tlsa_line = None
        for line in dns_value.split('\n'):
            if line.upper().startswith("TLSA="):
                tlsa_line = line.split("=", 1)[1].strip()
                break

        if not tlsa_line:
            return f"HARD FAIL: No TLSA configuration found inside the EmerDNS record for {emer_dns_domain}. Aborting."

        # Parse DANE/TLSA components: e.g., "3 1 1 a1b2c3d4..."
        parts = tlsa_line.split()
        if len(parts) < 4:
            return "HARD FAIL: Malformed TLSA record on-chain. Configuration cannot be parsed securely."
            
        usage, selector, matching_type = int(parts[0]), int(parts[1]), int(parts[2])
        onchain_association_data = "".join(parts[3:]).lower()

        # 3. Pull the live certificate directly from the host network socket over TLS
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE  # Explicitly pulling raw cert to calculate DANE fingerprints manually
        
        with socket.create_connection((host, port), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=host) as ssock:
                der_cert = ssock.getpeercert(binary_form=True)

        # 4. Process DANE Matching Rules natively
        cert = x509.load_der_x509_certificate(der_cert)
        
        # Selector 0 = Full Certificate, Selector 1 = SubjectPublicKeyInfo (SPKI)
        if selector == 0:
            target_bytes = der_cert
        elif selector == 1:
            target_bytes = cert.public_key().public_bytes(
                encoding=serialization.Encoding.DER,
                format=serialization.PublicFormat.SubjectPublicKeyInfo
            )
        else:
            return f"HARD FAIL: Unsupported TLSA Selector type ({selector})."

        # Matching Type 0 = Exact bytes, 1 = SHA-256 hash, 2 = SHA-512 hash
        if matching_type == 0:
            calculated_fingerprint = target_bytes.hex().lower()
        elif matching_type == 1:
            calculated_fingerprint = hashlib.sha256(target_bytes).hexdigest().lower()
        elif matching_type == 2:
            calculated_fingerprint = hashlib.sha512(target_bytes).hexdigest().lower()
        else:
            return f"HARD FAIL: Unsupported TLSA Matching Type ({matching_type})."

        # 5. Enforce Strict DANE Trust Match (FAIL HARD on mismatch)
        if calculated_fingerprint != onchain_association_data:
            return json.dumps({
                "status": "CRITICAL_SECURITY_BREACH",
                "message": f"HARD FAIL: Live node TLS cert fingerprint ({calculated_fingerprint}) does not match the on-chain EmerDNS TLSA record ({onchain_association_data})! Hostile intercept or spoofing detected."
            }, indent=2)

        return json.dumps({
            "status": "TRUST_ESTABLISHED",
            "message": "Decentralized DANE/TLSA verification complete. Node trust verified via EmerDNS.",
            "domain_verified": emer_dns_domain,
            "dane_usage_type": usage
        }, indent=2)

    except Exception as e:
        return f"Sovereign TLSA Verification failed due to system exception: {str(e)}"

@mcp.tool()
def update_ness_persona(
    id_username: str, ipfs_hash: str, magnet_link: str, pubkey: str,
    skywire_pubkey: str = "", created_timestamp: str = "", anchor_block: str = "", days_valid: int = 365
) -> str:
    """Assembles and commits a well-defined WORM v1.0 identity record to EmerNVS."""
    missing_inputs = []
    if not id_username: missing_inputs.append("id_username")
    if not ipfs_hash: missing_inputs.append("ipfs_hash")
    if not magnet_link: missing_inputs.append("magnet_link")
    if not pubkey: missing_inputs.append("pubkey")
    if not created_timestamp: missing_inputs.append("created_timestamp")
    if not anchor_block: missing_inputs.append("anchor_block")
    
    if missing_inputs:
        return json.dumps({"status": "INPUT_REQUIRED", "prompt_user_for": missing_inputs})

    try:
        worm_root = ET.Element("worm", {"version": "1.0", "type": "id"})
        meta_elem = ET.SubElement(worm_root, "meta")
        ET.SubElement(meta_elem, "schema").text = "worm:id:1.0"
        ET.SubElement(meta_elem, "created").text = created_timestamp
        ET.SubElement(meta_elem, "anchor_block").text = str(anchor_block)
        
        id_elem = ET.SubElement(worm_root, "identity")
        ET.SubElement(id_elem, "nvs_key").text = f"id:{id_username}"
        ET.SubElement(id_elem, "pubkey_algo").text = "Ed25519"
        ET.SubElement(id_elem, "pubkey").text = pubkey
        
        if skywire_pubkey:
            ET.SubElement(id_elem, "skywire_pubkey").text = skywire_pubkey
            
        node_elem = ET.SubElement(worm_root, "node", {"type": "ness", "url": f"http://ness.cx{ipfs_hash}", "network": "inet"})
        ET.SubElement(node_elem, "ipfs_cid").text = ipfs_hash
        ET.SubElement(node_elem, "magnet_uri").text = magnet_link

        worm_xml_payload = ET.tostring(worm_root, encoding='utf-8').decode('utf-8')
        nvs_key = f"id:{id_username}"
        rpc_result = call_local_rpc("name_new", [nvs_key, worm_xml_payload, days_valid])
        
        return json.dumps({"status": "SUCCESS", "nvs_key_written": nvs_key, "rpc_response": rpc_result}, indent=2)
    except Exception as ex:
        return f"XML Mapping failure: {str(ex)}"

if __name__ == "__main__":
    mcp.run()
