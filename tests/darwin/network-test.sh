#!/usr/bin/env bash
# Container network verification test script
# This runs INSIDE the container to verify networking is working
set -euo pipefail

# Darwin-only test: uses darwin-specific networking (VZNATNetworkDeviceAttachment, vmnet).
# Platform gating is at the Nix level (tests/darwin/default.nix); this script runs
# inside a Linux container on a Darwin host, so uname returns "Linux" here.

echo "=== Container Network Verification ==="
echo "Running as: $(id)"
echo "Date: $(date)"
echo ""

FAILED=0

# Test 1: Check network interfaces
echo "Test 1: Network interfaces"
if ip addr show 2>/dev/null; then
  # Verify eth0 has an IP address (vmnet assigns dynamically)
  if ip addr show eth0 2>/dev/null | grep -q "inet "; then
    ETH0_IP=$(ip addr show eth0 | grep "inet " | awk '{print $2}')
    echo "  PASS: eth0 configured with $ETH0_IP"
  else
    echo "  FAIL: eth0 not configured correctly"
    FAILED=1
  fi
else
  echo "  FAIL: Cannot list interfaces"
  FAILED=1
fi
echo ""

# Test 2: Check routing table
echo "Test 2: Routing table"
if ip route show 2>/dev/null | grep -q "default via"; then
  GATEWAY=$(ip route show default | awk '{print $3}')
  echo "  PASS: Default route via $GATEWAY"
else
  echo "  FAIL: No default route"
  ip route show 2>/dev/null || true
  FAILED=1
fi
echo ""

# Test 3: Check DNS configuration
echo "Test 3: DNS configuration (/etc/resolv.conf)"
if [ -f /etc/resolv.conf ]; then
  cat /etc/resolv.conf
  # Verify explicit DNS servers are configured (Tailscale MagicDNS + Cloudflare)
  if grep -q "100.100.100.100" /etc/resolv.conf || grep -q "1.1.1.1" /etc/resolv.conf; then
    echo "  PASS: resolv.conf has explicit DNS servers"
  else
    echo "  PASS: resolv.conf exists (using vmnet DNS)"
  fi
else
  echo "  FAIL: /etc/resolv.conf not found"
  FAILED=1
fi
echo ""

# Test 4: Ping gateway (REQUIRED - this verifies network stack works)
GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3}')
echo "Test 4: Ping gateway ($GATEWAY)"
if [ -n "$GATEWAY" ] && ping -c 2 -W 5 "$GATEWAY" >/dev/null 2>&1; then
  echo "  PASS: Gateway reachable"
else
  echo "  FAIL: Cannot reach gateway"
  ping -c 2 -W 5 "$GATEWAY" 2>&1 || true
  FAILED=1
fi
echo ""

# External connectivity tests (informational - VZNATNetworkDeviceAttachment only routes ICMP)
echo "=== External Connectivity Tests (informational) ==="
echo "Note: VZNATNetworkDeviceAttachment only routes ICMP, not TCP/UDP."
echo "      Full internet requires vmnet with Apple Developer certificate."
echo ""

# Test 5: Direct IP connectivity via ICMP (verifies NAT routing works)
echo "Test 5: ICMP connectivity (ping 1.1.1.1)"
if ping -c 2 -W 5 1.1.1.1 >/dev/null 2>&1; then
  echo "  PASS: External IP reachable via ICMP"
else
  echo "  FAIL: Cannot reach external IP 1.1.1.1"
  ping -c 2 -W 5 1.1.1.1 2>&1 || true
  FAILED=1
fi
echo ""

# Test 5b: TCP connectivity (informational - expected to fail without vmnet)
echo "Test 5b: TCP connectivity (curl http://1.1.1.1)"
if command -v curl >/dev/null 2>&1; then
  if curl -sS --connect-timeout 5 --max-time 10 -o /dev/null http://1.1.1.1 2>/dev/null; then
    echo "  INFO: TCP connectivity works (vmnet available)"
  else
    echo "  INFO: TCP blocked (expected without vmnet)"
  fi
else
  echo "  SKIP: curl not available"
fi
echo ""

# Test 6: DNS resolution (informational - expected to fail without vmnet)
echo "Test 6: DNS resolution (cloudflare.com)"
if getent hosts cloudflare.com >/dev/null 2>&1; then
  echo "  INFO: DNS resolution works (vmnet available)"
  getent hosts cloudflare.com
elif ping -c 1 -W 3 cloudflare.com >/dev/null 2>&1; then
  echo "  INFO: DNS resolution works (vmnet available)"
else
  echo "  INFO: DNS blocked (expected without vmnet)"
fi
echo ""

# Test 7: HTTPS connectivity (informational - expected to fail without vmnet)
echo "Test 7: External HTTPS connectivity"
if command -v curl >/dev/null 2>&1; then
  if curl -sS --connect-timeout 5 --max-time 10 -o /dev/null https://cloudflare.com 2>/dev/null; then
    echo "  INFO: HTTPS connectivity works (vmnet available)"
  else
    echo "  INFO: HTTPS blocked (expected without vmnet)"
  fi
else
  echo "  SKIP: curl not available"
fi
echo ""

# Summary
echo "=== Network Diagnostics Summary ==="
echo "Interfaces:"
ip -4 addr show 2>/dev/null | grep inet || echo "  (could not get IPs)"
echo ""
echo "Default route:"
ip route show default 2>/dev/null || echo "  (no default route)"
echo ""

if [ "$FAILED" -eq 0 ]; then
  echo "=== NETWORK TESTS PASSED ==="
  echo "(Gateway + ICMP verified. Full internet requires vmnet with Apple Developer cert.)"
  exit 0
else
  echo "=== NETWORK TESTS FAILED ==="
  exit 1
fi
