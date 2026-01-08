#!/bin/bash
# Container network verification test script
# This runs INSIDE the container to verify networking is working
set -e

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
  echo "  PASS: resolv.conf exists"
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

# External connectivity tests (informational - requires vmnet with Apple Developer cert)
echo "=== External Connectivity Tests (informational) ==="
echo "Note: Full internet access requires vmnet with Apple Developer certificate."
echo ""

# Test 5: DNS resolution (informational)
echo "Test 5: DNS resolution (cloudflare.com)"
if getent hosts cloudflare.com >/dev/null 2>&1; then
  echo "  INFO: DNS resolution works"
  getent hosts cloudflare.com
elif ping -c 1 -W 3 cloudflare.com >/dev/null 2>&1; then
  echo "  INFO: DNS resolution works (via ping)"
else
  echo "  INFO: DNS resolution not available (expected without vmnet)"
fi
echo ""

# Test 6: External connectivity (informational)
echo "Test 6: External HTTPS connectivity"
if command -v curl >/dev/null 2>&1; then
  if curl -sS --connect-timeout 5 --max-time 10 -o /dev/null https://cloudflare.com 2>/dev/null; then
    echo "  INFO: HTTPS connectivity works"
  else
    echo "  INFO: HTTPS not available (expected without vmnet)"
  fi
else
  echo "  INFO: curl not available"
fi
echo ""

# Test 7: Direct IP connectivity (informational)
echo "Test 7: Direct IP connectivity (1.1.1.1)"
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
  echo "  INFO: External IP reachable"
else
  echo "  INFO: External IP not reachable (expected without vmnet)"
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
  echo "(Gateway connectivity verified. Full internet requires vmnet with Apple Developer cert.)"
  exit 0
else
  echo "=== NETWORK TESTS FAILED ==="
  exit 1
fi
