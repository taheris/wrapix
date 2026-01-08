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
ip addr show 2>/dev/null || ifconfig -a 2>/dev/null || { echo "  FAIL: Cannot list interfaces"; FAILED=1; }
echo ""

# Test 2: Check routing table
echo "Test 2: Routing table"
ip route show 2>/dev/null || netstat -rn 2>/dev/null || { echo "  FAIL: Cannot show routes"; FAILED=1; }
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

# Test 4: Ping gateway
echo "Test 4: Ping gateway (10.0.0.1)"
if ping -c 2 -W 5 10.0.0.1 >/dev/null 2>&1; then
  echo "  PASS: Gateway reachable"
else
  echo "  FAIL: Cannot reach gateway"
  ping -c 2 -W 5 10.0.0.1 2>&1 || true
  FAILED=1
fi
echo ""

# Test 5: DNS resolution
echo "Test 5: DNS resolution (cloudflare.com)"
if nslookup cloudflare.com >/dev/null 2>&1; then
  echo "  PASS: DNS resolution works"
  nslookup cloudflare.com 2>&1 | head -5
elif getent hosts cloudflare.com >/dev/null 2>&1; then
  echo "  PASS: DNS resolution works (getent)"
  getent hosts cloudflare.com
elif ping -c 1 -W 5 cloudflare.com >/dev/null 2>&1; then
  echo "  PASS: DNS resolution works (via ping)"
else
  echo "  FAIL: DNS resolution failed"
  echo "  Trying direct DNS query to 1.1.1.1..."
  nslookup cloudflare.com 1.1.1.1 2>&1 || true
  FAILED=1
fi
echo ""

# Test 6: External connectivity (HTTPS)
echo "Test 6: External HTTPS connectivity"
if command -v curl >/dev/null 2>&1; then
  if curl -sS --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" https://cloudflare.com 2>/dev/null | grep -q "^[23]"; then
    echo "  PASS: HTTPS connectivity works"
  else
    echo "  FAIL: HTTPS request failed"
    curl -vvv --connect-timeout 10 https://cloudflare.com 2>&1 | head -30 || true
    FAILED=1
  fi
elif command -v wget >/dev/null 2>&1; then
  if wget -q --timeout=10 -O /dev/null https://cloudflare.com 2>/dev/null; then
    echo "  PASS: HTTPS connectivity works (wget)"
  else
    echo "  FAIL: HTTPS request failed"
    wget --timeout=10 -O /dev/null https://cloudflare.com 2>&1 || true
    FAILED=1
  fi
else
  echo "  SKIP: No curl or wget available"
fi
echo ""

# Test 7: Check if we can reach common IPs directly
echo "Test 7: Direct IP connectivity (1.1.1.1)"
if ping -c 2 -W 5 1.1.1.1 >/dev/null 2>&1; then
  echo "  PASS: Can reach 1.1.1.1"
else
  echo "  FAIL: Cannot reach 1.1.1.1"
  ping -c 2 -W 5 1.1.1.1 2>&1 || true
  FAILED=1
fi
echo ""

# Summary
echo "=== Network Diagnostics Summary ==="
echo "Interfaces:"
ip -4 addr show 2>/dev/null | grep inet || ifconfig 2>/dev/null | grep "inet " || echo "  (could not get IPs)"
echo ""
echo "Default route:"
ip route show default 2>/dev/null || netstat -rn 2>/dev/null | grep default || echo "  (no default route)"
echo ""

if [ "$FAILED" -eq 0 ]; then
  echo "=== ALL NETWORK TESTS PASSED ==="
  exit 0
else
  echo "=== SOME NETWORK TESTS FAILED ==="
  exit 1
fi
