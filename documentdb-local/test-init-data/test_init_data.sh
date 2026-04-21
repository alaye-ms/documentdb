#!/bin/bash

# Script to test custom initialization data behavior in DocumentDB.
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONTAINER_NAME="documentdb-gateway-test"
IMAGE_NAME="documentdb-gateway-test"
INIT_DATA_DIR="$SCRIPT_DIR/test-init-data"
DOCKERFILE_PATH="$PROJECT_ROOT/packaging/gateway/docker/Dockerfile_documentdb_local"
PACKAGE_OUTPUT_DIR="downloaded-artifacts"
PACKAGE_OS="deb13"
PACKAGE_PG_VERSION="17"
DOCUMENTDB_PORT="10261"
PASSWORD="TestPassword123"

echo "=== DocumentDB Custom Init Data Feature Test ==="
echo "Project Root: $PROJECT_ROOT"
echo "Script Directory: $SCRIPT_DIR"
echo "Container: $CONTAINER_NAME"
echo "Image: $IMAGE_NAME"
echo "Init Data Directory: $INIT_DATA_DIR"
echo "Dockerfile: $DOCKERFILE_PATH"
echo "DocumentDB Port: $DOCUMENTDB_PORT"
echo "Package OS: $PACKAGE_OS"
echo "Package PostgreSQL Version: $PACKAGE_PG_VERSION"
echo

# Function to check if mongosh is available
check_mongosh() {
    echo "=== Checking Prerequisites ==="
    if ! command -v mongosh >/dev/null 2>&1; then
        echo "❌ Error: mongosh is not installed or not in PATH"
        echo "Please install MongoDB Shell (mongosh) to run this test."
        echo "Visit: https://docs.mongodb.com/mongodb-shell/install/"
        exit 1
    fi
    echo "✅ mongosh is available: $(mongosh --version)"
    echo
}

# Function to build the Docker image
build_image() {
    echo "=== Building Docker Image ==="
    if [ ! -f "$DOCKERFILE_PATH" ]; then
        echo "Error: Dockerfile not found at $DOCKERFILE_PATH"
        exit 1
    fi

    echo "Building DocumentDB package for the local image..."
    (
        cd "$PROJECT_ROOT"
        ./packaging/build_packages.sh --os "$PACKAGE_OS" --pg "$PACKAGE_PG_VERSION" --output-dir "$PACKAGE_OUTPUT_DIR"
    )

    local deb_package_name
    deb_package_name=$(ls "$PROJECT_ROOT/$PACKAGE_OUTPUT_DIR" | grep -E "${PACKAGE_OS}-postgresql-${PACKAGE_PG_VERSION}-documentdb_.*\\.deb" | grep -v 'dbgsym' | head -n 1)
    if [ -z "$deb_package_name" ]; then
        echo "Error: Built package not found in $PROJECT_ROOT/$PACKAGE_OUTPUT_DIR"
        exit 1
    fi

    local deb_package_rel_path="$PACKAGE_OUTPUT_DIR/$deb_package_name"

    echo "Building image $IMAGE_NAME from $DOCKERFILE_PATH using $deb_package_rel_path..."
    docker build \
        --build-arg BASE_IMAGE=debian:trixie-slim \
        --build-arg POSTGRES_VERSION="$PACKAGE_PG_VERSION" \
        --build-arg DEB_PACKAGE_REL_PATH="$deb_package_rel_path" \
        -f "$DOCKERFILE_PATH" \
        -t "$IMAGE_NAME" \
        "$PROJECT_ROOT"

    echo "✅ Image built successfully"
    echo
}

# Function to cleanup previous runs
cleanup() {
    echo "Cleaning up previous containers..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    docker stop "${CONTAINER_NAME}-skip-false" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}-skip-false" 2>/dev/null || true
    docker stop "${CONTAINER_NAME}-default-path" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}-default-path" 2>/dev/null || true
}

# Function to wait for DocumentDB to be ready
wait_for_documentdb() {
    local cname=$1
    local cport=$2

    echo "Waiting for DocumentDB to be ready..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
            echo "✅ DocumentDB is ready for container $cname!"
            return 0
        fi

        echo "Attempt $attempt/$max_attempts - waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "❌ Error: DocumentDB did not become ready"
    return 1
}

# Function to wait for custom data initialization to complete by monitoring logs
wait_for_data_initialization() {
    local cname=$1

    echo "Waiting for custom data initialization to complete..."
    local max_attempts=120
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if docker logs "$cname" 2>&1 | grep -q "Custom data initialization completed."; then
            sleep 5
            echo "✅ Custom data initialization completed!"
            return 0
        fi

        echo "Attempt $attempt/$max_attempts - waiting for custom initialization completion log..."
        sleep 3
        attempt=$((attempt + 1))
    done

    echo "❌ Error: Custom data initialization did not complete within timeout"
    echo "=== Recent Container Logs ==="
    docker logs --tail 20 "$cname"
    return 1
}

# Function to verify custom data loaded and built-in sample data did not load
verify_custom_only() {
    local cname=$1
    local cport=$2
    local db_list
    local users
    local products
    local orders

    echo "=== Verifying Custom Data Only ==="

    if docker logs "$cname" 2>&1 | grep -q "Initializing database with built-in sample data"; then
        echo "❌ Built-in sample data initialization was triggered unexpectedly"
        return 1
    fi
    echo "✅ Built-in sample data initialization was not triggered"

    db_list=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "db.adminCommand('listDatabases')" --quiet 2>/dev/null)
    if [[ "$db_list" == *"sampledb"* ]]; then
        echo "❌ sampledb database found"
        echo "$db_list"
        return 1
    fi
    echo "✅ sampledb database absent"

    users=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.countDocuments()" --quiet 2>/dev/null | tail -1)
    products=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.countDocuments()" --quiet 2>/dev/null | tail -1)
    orders=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.countDocuments()" --quiet 2>/dev/null | tail -1)

    if [ "$users" != "4" ] || [ "$products" != "4" ] || [ "$orders" != "4" ]; then
        echo "❌ Custom data counts were incorrect (users=$users products=$products orders=$orders)"
        return 1
    fi

    echo "✅ Custom data loaded with expected collection counts"
    return 0
}

# Function to verify the initialized data with comprehensive checks
verify_data() {
    local cname=$1
    local cport=$2

    echo "=== Verifying Initialized Data ==="

    if ! verify_custom_only "$cname" "$cport"; then
        return 1
    fi

    # Check users collection
    echo "Checking users collection..."
    USER_COUNT=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Users count: $USER_COUNT"

    # Check products collection
    echo "Checking products collection..."
    PRODUCT_COUNT=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Products count: $PRODUCT_COUNT"

    # Check orders collection
    echo "Checking orders collection..."
    ORDER_COUNT=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.countDocuments()" --quiet 2>/dev/null | tail -1)
    echo "Orders count: $ORDER_COUNT"

    # Show sample data from each collection
    echo
    echo "=== Sample Data ==="
    echo "Sample user:"
    mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.findOne()" --quiet 2>/dev/null

    echo
    echo "Sample product:"
    mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.findOne()" --quiet 2>/dev/null

    echo
    echo "Sample order:"
    mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.findOne()" --quiet 2>/dev/null

    # Verify indexes were created
    echo
    echo "=== Checking Indexes ==="
    echo "Users indexes:"
    mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.getIndexes()" --quiet 2>/dev/null

    echo
    echo "Products indexes:"
    mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.getIndexes()" --quiet 2>/dev/null

    echo
    echo "Orders indexes:"
    mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.getIndexes()" --quiet 2>/dev/null

    # Test some queries
    echo
    echo "=== Query Tests ==="
    echo "Testing query: Users with age > 30"
    ADULT_USERS=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.users.countDocuments({age: {\$gt: 30}})" --quiet 2>/dev/null | tail -1)
    echo "Adult users (age > 30): $ADULT_USERS"

    echo "Testing query: Products in stock"
    IN_STOCK_PRODUCTS=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.products.countDocuments({inStock: true})" --quiet 2>/dev/null | tail -1)
    echo "Products in stock: $IN_STOCK_PRODUCTS"

    echo "Testing query: Completed orders"
    COMPLETED_ORDERS=$(mongosh localhost:$cport -u default_user -p $PASSWORD --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates --eval "use('test'); db.orders.countDocuments({status: 'completed'})" --quiet 2>/dev/null | tail -1)
    echo "Completed orders: $COMPLETED_ORDERS"
}

test_init_data_path_only() {
    local cname="$CONTAINER_NAME"
    local cport="$DOCUMENTDB_PORT"

    echo
    echo "=== Testing --init-data-path Only ==="

    cleanup

    if ! docker run -d \
        --name "$cname" \
        -p $cport:10260 \
        -e PASSWORD=$PASSWORD \
        -v "$INIT_DATA_DIR:/init_doc_db.d" \
        $IMAGE_NAME \
        --password $PASSWORD \
        --init-data-path /init_doc_db.d; then
        echo "❌ Failed to start --init-data-path only test container"
        return 1
    fi

    if ! wait_for_documentdb "$cname" "$cport"; then
        echo "❌ --init-data-path only test container failed to start"
        docker logs "$cname"
        return 1
    fi

    if ! wait_for_data_initialization "$cname"; then
        return 1
    fi

    if ! verify_data "$cname" "$cport"; then
        docker logs --tail 40 "$cname"
        return 1
    fi

    echo "✅ --init-data-path only test passed"
    return 0
}

test_init_data_path_with_skip_false_env() {
    local cname="${CONTAINER_NAME}-skip-false"
    local cport=$((DOCUMENTDB_PORT + 1))

    echo
    echo "=== Testing SKIP_INIT_DATA=false + --init-data-path ==="

    cleanup

    if ! docker run -d \
        --name "$cname" \
        -p $cport:10260 \
        -e PASSWORD=$PASSWORD \
        -e SKIP_INIT_DATA=false \
        -v "$INIT_DATA_DIR:/init_doc_db.d" \
        $IMAGE_NAME \
        --password $PASSWORD \
        --init-data-path /init_doc_db.d; then
        echo "❌ Failed to start SKIP_INIT_DATA=false + --init-data-path test container"
        return 1
    fi

    if ! wait_for_documentdb "$cname" "$cport"; then
        echo "❌ SKIP_INIT_DATA=false + --init-data-path test container failed to start"
        docker logs "$cname"
        return 1
    fi

    if ! wait_for_data_initialization "$cname"; then
        return 1
    fi

    if ! verify_custom_only "$cname" "$cport"; then
        docker logs --tail 40 "$cname"
        return 1
    fi

    echo "✅ SKIP_INIT_DATA=false + --init-data-path test passed"
    return 0
}

test_default_init_path_mount_only() {
    local cname="${CONTAINER_NAME}-default-path"
    local cport=$((DOCUMENTDB_PORT + 2))

    echo
    echo "=== Testing Default /init_doc_db.d Mount Only ==="

    cleanup

    if ! docker run -d \
        --name "$cname" \
        -p $cport:10260 \
        -e PASSWORD=$PASSWORD \
        -v "$INIT_DATA_DIR:/init_doc_db.d" \
        $IMAGE_NAME \
        --password $PASSWORD; then
        echo "❌ Failed to start default /init_doc_db.d mount-only test container"
        return 1
    fi

    if ! wait_for_documentdb "$cname" "$cport"; then
        echo "❌ Default /init_doc_db.d mount-only test container failed to start"
        docker logs "$cname"
        return 1
    fi

    if ! wait_for_data_initialization "$cname"; then
        return 1
    fi

    if ! verify_custom_only "$cname" "$cport"; then
        docker logs --tail 40 "$cname"
        return 1
    fi

    echo "✅ Default /init_doc_db.d mount-only test passed"
    return 0
}

# Main test execution
main() {
    check_mongosh

    cleanup

    build_image

    if [ ! -d "$INIT_DATA_DIR" ]; then
        echo "Error: Init data directory not found at $INIT_DATA_DIR"
        exit 1
    fi

    echo "Init data files found:"
    ls -la "$INIT_DATA_DIR"/*.js
    echo

    if test_init_data_path_only; then
        PATH_ONLY_RESULT=0
    else
        PATH_ONLY_RESULT=$?
    fi

    if test_init_data_path_with_skip_false_env; then
        PATH_SKIP_FALSE_RESULT=0
    else
        PATH_SKIP_FALSE_RESULT=$?
    fi

    if test_default_init_path_mount_only; then
        DEFAULT_PATH_RESULT=0
    else
        DEFAULT_PATH_RESULT=$?
    fi

    echo
    echo "=== Test Results Summary ==="

    EXPECTED_USERS=4
    EXPECTED_PRODUCTS=4
    EXPECTED_ORDERS=4
    EXPECTED_ADULT_USERS=3
    EXPECTED_IN_STOCK=3
    EXPECTED_COMPLETED=1

    USERS_PASS=$([[ "$USER_COUNT" == "$EXPECTED_USERS" ]] && echo "✅" || echo "❌")
    PRODUCTS_PASS=$([[ "$PRODUCT_COUNT" == "$EXPECTED_PRODUCTS" ]] && echo "✅" || echo "❌")
    ORDERS_PASS=$([[ "$ORDER_COUNT" == "$EXPECTED_ORDERS" ]] && echo "✅" || echo "❌")
    ADULT_USERS_PASS=$([[ "$ADULT_USERS" == "$EXPECTED_ADULT_USERS" ]] && echo "✅" || echo "❌")
    IN_STOCK_PASS=$([[ "$IN_STOCK_PRODUCTS" == "$EXPECTED_IN_STOCK" ]] && echo "✅" || echo "❌")
    COMPLETED_PASS=$([[ "$COMPLETED_ORDERS" == "$EXPECTED_COMPLETED" ]] && echo "✅" || echo "❌")
    PATH_ONLY_PASS=$([[ "$PATH_ONLY_RESULT" == "0" ]] && echo "✅" || echo "❌")
    PATH_SKIP_FALSE_PASS=$([[ "$PATH_SKIP_FALSE_RESULT" == "0" ]] && echo "✅" || echo "❌")
    DEFAULT_PATH_PASS=$([[ "$DEFAULT_PATH_RESULT" == "0" ]] && echo "✅" || echo "❌")

    echo "┌────────────────────────────────────┬──────────┬──────────┬────────┐"
    echo "│ Test Case                          │ Expected │ Actual   │ Result │"
    echo "├────────────────────────────────────┼──────────┼──────────┼────────┤"
    echo "│ Users Collection                   │ $EXPECTED_USERS        │ $USER_COUNT        │ $USERS_PASS     │"
    echo "│ Products Collection                │ $EXPECTED_PRODUCTS        │ $PRODUCT_COUNT        │ $PRODUCTS_PASS     │"
    echo "│ Orders Collection                  │ $EXPECTED_ORDERS        │ $ORDER_COUNT        │ $ORDERS_PASS     │"
    echo "│ Adult Users (age > 30)             │ $EXPECTED_ADULT_USERS        │ $ADULT_USERS        │ $ADULT_USERS_PASS     │"
    echo "│ Products In Stock                  │ $EXPECTED_IN_STOCK        │ $IN_STOCK_PRODUCTS        │ $IN_STOCK_PASS     │"
    echo "│ Completed Orders                   │ $EXPECTED_COMPLETED        │ $COMPLETED_ORDERS        │ $COMPLETED_PASS     │"
    echo "│ --init-data-path Only              │ PASS     │ $([ "$PATH_ONLY_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $PATH_ONLY_PASS     │"
    echo "│ SKIP_INIT_DATA=false + path        │ PASS     │ $([ "$PATH_SKIP_FALSE_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $PATH_SKIP_FALSE_PASS     │"
    echo "│ Default /init_doc_db.d mount only  │ PASS     │ $([ "$DEFAULT_PATH_RESULT" = "0" ] && echo "PASS" || echo "FAIL")     │ $DEFAULT_PATH_PASS     │"
    echo "└────────────────────────────────────┴──────────┴──────────┴────────┘"
    echo

    ALL_TESTS_PASSED=true
    [ "$USER_COUNT" != "$EXPECTED_USERS" ] && ALL_TESTS_PASSED=false
    [ "$PRODUCT_COUNT" != "$EXPECTED_PRODUCTS" ] && ALL_TESTS_PASSED=false
    [ "$ORDER_COUNT" != "$EXPECTED_ORDERS" ] && ALL_TESTS_PASSED=false
    [ "$ADULT_USERS" != "$EXPECTED_ADULT_USERS" ] && ALL_TESTS_PASSED=false
    [ "$IN_STOCK_PRODUCTS" != "$EXPECTED_IN_STOCK" ] && ALL_TESTS_PASSED=false
    [ "$COMPLETED_ORDERS" != "$EXPECTED_COMPLETED" ] && ALL_TESTS_PASSED=false
    [ "$PATH_ONLY_RESULT" != "0" ] && ALL_TESTS_PASSED=false
    [ "$PATH_SKIP_FALSE_RESULT" != "0" ] && ALL_TESTS_PASSED=false
    [ "$DEFAULT_PATH_RESULT" != "0" ] && ALL_TESTS_PASSED=false

    if [ "$ALL_TESTS_PASSED" = true ]; then
        echo "🎉 OVERALL RESULT: SUCCESS! All tests passed."
        echo "✅ Docker build completed successfully"
        echo "✅ Custom initialization data loaded correctly"
        echo "✅ Built-in sample data was suppressed in every custom-data scenario"
        echo "✅ All collections created with expected data"
        echo "✅ All indexes created successfully"
        echo "✅ All queries work as expected"
        OVERALL_RESULT="SUCCESS"
    else
        echo "❌ OVERALL RESULT: FAILURE! Some tests failed."
        echo "Please check the detailed results above."
        OVERALL_RESULT="FAILURE"
    fi

    echo
    echo "=== Post-Test Information ==="
    echo "Stopping and cleaning up the test containers..."
    cleanup
    echo "✅ Containers stopped and removed successfully"
    echo
    echo "You can:"
    echo "1. Remove image: docker rmi $IMAGE_NAME"
    echo "2. Run test again: ./test_init_data.sh"
    echo

    if [ "$OVERALL_RESULT" = "SUCCESS" ]; then
        exit 0
    else
        exit 1
    fi
}

# Run the test
main "$@"
