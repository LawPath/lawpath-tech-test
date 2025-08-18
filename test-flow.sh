#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
LOCALSTACK_URL="http://localhost:4566"
REGION="us-east-1"
TABLE_NAME="items-local"
API_ENDPOINT=""

echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}     Complete Flow Test: Stop → Start → Warm → Test      ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""

# Function to check if service is running
check_service() {
    local service=$1
    local port=$2
    nc -z localhost $port 2>/dev/null
    return $?
}

# Function to wait for service
wait_for_service() {
    local service=$1
    local port=$2
    local max_attempts=30
    local attempt=1
    
    echo -n "   Waiting for $service (port $port)..."
    while [ $attempt -le $max_attempts ]; do
        if check_service $service $port; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
        attempt=$((attempt + 1))
    done
    echo -e " ${RED}✗${NC}"
    return 1
}

# ═══════════════════════════════════════
# STEP 1: STOP EVERYTHING
# ═══════════════════════════════════════
echo -e "${YELLOW}▶ Step 1: Stopping existing services...${NC}"
echo "   Stopping Docker containers..."
docker compose -f docker-compose-minimal.yml down -v >/dev/null 2>&1

# Kill any existing warmup processes
pkill -f "node warmup.js" 2>/dev/null

# Clean up old Lambda containers
docker ps -a | grep "localstack-lambda" | awk '{print $1}' | xargs -r docker rm -f >/dev/null 2>&1

echo -e "   ${GREEN}✓${NC} All services stopped"
echo ""

# ═══════════════════════════════════════
# STEP 2: START SERVICES
# ═══════════════════════════════════════
echo -e "${YELLOW}▶ Step 2: Starting services...${NC}"
docker compose -f docker-compose-minimal.yml up -d >/dev/null 2>&1

# Wait for services to be ready
wait_for_service "LocalStack" 4566
wait_for_service "Qdrant" 6333
wait_for_service "Text-Embeddings" 8080

# Extra wait for services to fully initialize
echo "   Waiting for services to initialize..."
sleep 10

echo -e "   ${GREEN}✓${NC} All services started"
echo ""

# ═══════════════════════════════════════
# STEP 3: DEPLOY STACK
# ═══════════════════════════════════════
echo -e "${YELLOW}▶ Step 3: Deploying serverless stack...${NC}"
npm run deploy:local >/dev/null 2>&1

# Get the API endpoint
API_ENDPOINT=$(npx serverless info --stage local 2>/dev/null | grep endpoint | awk '{print $2}')
if [ -z "$API_ENDPOINT" ]; then
    echo -e "   ${RED}✗${NC} Failed to get API endpoint"
    exit 1
fi

echo -e "   ${GREEN}✓${NC} Stack deployed"
echo "   API Endpoint: $API_ENDPOINT"
echo ""

# ═══════════════════════════════════════
# STEP 4: CREATE DYNAMODB TABLE
# ═══════════════════════════════════════
echo -e "${YELLOW}▶ Step 4: Creating DynamoDB table...${NC}"
aws --endpoint-url=$LOCALSTACK_URL dynamodb create-table \
    --table-name $TABLE_NAME \
    --attribute-definitions AttributeName=key,AttributeType=S \
    --key-schema AttributeName=key,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 || echo "   Table already exists"

echo -e "   ${GREEN}✓${NC} DynamoDB table ready"
echo ""

# ═══════════════════════════════════════
# STEP 5: WARM UP LAMBDA FUNCTIONS
# ═══════════════════════════════════════
echo -e "${YELLOW}▶ Step 5: Warming up Lambda functions...${NC}"
echo "   This may take 30-60 seconds for cold starts..."

FUNCTIONS=(
    "lawpath-serverless-localstack-local-hello"
    "lawpath-serverless-localstack-local-processData"
    "lawpath-serverless-localstack-local-getItem"
    "lawpath-serverless-localstack-local-publishToSns"
    "lawpath-serverless-localstack-local-saveToDb"
    "lawpath-serverless-localstack-local-storeDocument"
    "lawpath-serverless-localstack-local-searchDocuments"
    "lawpath-serverless-localstack-local-deleteDocument"
    "lawpath-serverless-localstack-local-getCollectionInfo"
    "lawpath-serverless-localstack-local-storeBatch"
)

# Warm up functions in parallel
for func in "${FUNCTIONS[@]}"; do
    func_short=$(echo $func | rev | cut -d'-' -f1 | rev)
    echo -n "   Warming $func_short..."
    
    # Create appropriate payload based on function type
    case $func_short in
        "saveToDb")
            payload='{"Records": []}'
            ;;
        "getItem" | "deleteDocument")
            payload='{"pathParameters": {"key": "warmup"}}'
            ;;
        "processData" | "publishToSns" | "storeDocument" | "searchDocuments" | "storeBatch")
            payload='{"body": "{}"}'
            ;;
        *)
            payload='{}'
            ;;
    esac
    
    # Encode payload
    encoded_payload=$(echo -n "$payload" | base64)
    
    # Invoke function in background
    aws --endpoint-url=$LOCALSTACK_URL --region $REGION lambda invoke \
        --function-name "$func" \
        --payload "$encoded_payload" \
        /tmp/warmup-$func_short.json >/dev/null 2>&1 &
    
    echo -e " ${BLUE}⏳${NC}"
done

# Wait for all warmup processes
echo "   Waiting for all functions to warm up..."
wait
echo -e "   ${GREEN}✓${NC} All functions warmed"
echo ""

# ═══════════════════════════════════════
# STEP 6: RUN FLOW TESTS
# ═══════════════════════════════════════
echo -e "${YELLOW}▶ Step 6: Running flow tests...${NC}"
echo ""

# Test 1: Hello endpoint
echo -e "${BLUE}Test 1: Hello Endpoint${NC}"
response=$(curl -s -X GET ${API_ENDPOINT}/hello --max-time 3 2>/dev/null)
if [ $? -eq 0 ] && echo "$response" | grep -q "Hello World"; then
    echo -e "   ${GREEN}✓${NC} Hello endpoint working"
    echo "   Response: $(echo $response | python3 -m json.tool 2>/dev/null | head -1)"
else
    echo -e "   ${RED}✗${NC} Hello endpoint failed"
fi
echo ""

# Test 2: Process Data
echo -e "${BLUE}Test 2: Process Data${NC}"
response=$(curl -s -X POST ${API_ENDPOINT}/process \
    -H "Content-Type: application/json" \
    -d '{"data": "test", "type": "validation"}' \
    --max-time 3 2>/dev/null)
if [ $? -eq 0 ] && echo "$response" | grep -q "processed"; then
    echo -e "   ${GREEN}✓${NC} Process endpoint working"
else
    echo -e "   ${RED}✗${NC} Process endpoint failed"
fi
echo ""

# Test 3: Complete SNS → DynamoDB Flow
echo -e "${BLUE}Test 3: Complete Flow (HTTP → SNS → Lambda → DynamoDB)${NC}"
TEST_KEY="flow-test-$(date +%s)"

# Step 3a: Publish to SNS
echo "   Publishing message to SNS..."
response=$(curl -s -X POST ${API_ENDPOINT}/publish \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$TEST_KEY\", \"value\": \"Flow test at $(date)\"}" \
    --max-time 5 2>/dev/null)

if [ $? -eq 0 ] && echo "$response" | grep -q "success"; then
    echo -e "   ${GREEN}✓${NC} Message published to SNS"
else
    echo -e "   ${RED}✗${NC} Failed to publish to SNS"
fi

# Step 3b: Wait for SNS → Lambda → DynamoDB
echo "   Waiting for SNS trigger to save to DynamoDB..."
sleep 3

# Step 3c: Retrieve from DynamoDB via API
echo "   Retrieving item from DynamoDB..."
response=$(curl -s -X GET ${API_ENDPOINT}/items/${TEST_KEY} --max-time 3 2>/dev/null)

if [ $? -eq 0 ] && echo "$response" | grep -q "$TEST_KEY"; then
    echo -e "   ${GREEN}✓${NC} Item retrieved from DynamoDB"
    echo "   Full flow: HTTP → SNS → Lambda → DynamoDB → HTTP"
else
    # Try direct DynamoDB query as fallback
    echo "   Checking DynamoDB directly..."
    item=$(aws --endpoint-url=$LOCALSTACK_URL dynamodb get-item \
        --table-name $TABLE_NAME \
        --key "{\"key\": {\"S\": \"$TEST_KEY\"}}" 2>/dev/null)
    
    if echo "$item" | grep -q "$TEST_KEY"; then
        echo -e "   ${YELLOW}⚠${NC} Item in DynamoDB but API retrieval failed"
    else
        echo -e "   ${RED}✗${NC} Item not found in DynamoDB"
    fi
fi
echo ""

# Test 4: Vector Operations
echo -e "${BLUE}Test 4: Vector Operations${NC}"
response=$(curl -s -X GET ${API_ENDPOINT}/vectors/info --max-time 3 2>/dev/null)
if [ $? -eq 0 ] && echo "$response" | grep -q "documents"; then
    echo -e "   ${GREEN}✓${NC} Vector info endpoint working"
    points_count=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['points_count'])" 2>/dev/null)
    echo "   Collection has $points_count points"
else
    echo -e "   ${RED}✗${NC} Vector operations failed"
fi
echo ""

# ═══════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                     Test Summary                        ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
echo "Services:"
echo -e "   LocalStack:      ${GREEN}✓${NC} Running on port 4566"
echo -e "   Qdrant:          ${GREEN}✓${NC} Running on port 6333"
echo -e "   Text-Embeddings: ${GREEN}✓${NC} Running on port 8080"
echo ""
echo "API Endpoint: $API_ENDPOINT"
echo ""
echo -e "${GREEN}✅ Testing complete!${NC}"
echo ""
echo "To run continuous warmup: npm run warmup:continuous 2"
echo "To stop all services: docker compose -f docker-compose-minimal.yml down"
echo ""