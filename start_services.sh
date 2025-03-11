#!/bin/bash
#        _____
#      .-'.  ':'-.
#    .''::: .:    '.
#   /   :::::'      \
#  ;.    ':' `       ;
#  |       '..       |
#  ; '      ::::.    ;
#   \       '::::   /
#    '.      :::  .'
#      '-.___'_.-'
# Set error handling
set -e
trap 'echo "Error occurred in script at line $LINENO"; cleanup' ERR INT TERM

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    pkill -f "kafka" 2>/dev/null
    pkill -f "zookeeper" 2>/dev/null
    pkill -f "mosquitto" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f /tmp/*.log /tmp/mosquitto.conf /tmp/*.txt /tmp/*.html /tmp/stop_collectors 2>/dev/null
}

# Function to install necessary Python packages
install_python_packages() {
    echo "Installing necessary Python packages..."
    pip install --upgrade pip || { echo "Failed to upgrade pip"; return 1; }
    pip install opcua || { echo "Failed to install opcua"; return 1; }
    echo "Python packages installed."
}

# Function to check and install Java
check_java() {
    echo "Checking Java installation..."
    if ! command -v java &> /dev/null; then
        echo "Java not found. Installing OpenJDK..."
        brew install openjdk || { echo "Failed to install OpenJDK"; return 1; }
        sudo ln -sfn "$(brew --prefix openjdk)/libexec/openjdk.jdk" /Library/Java/JavaVirtualMachines/openjdk.jdk
        echo 'export PATH="$(brew --prefix openjdk)/bin:$PATH"' >> ~/.zshrc
        source ~/.zshrc
    fi
    echo "Java installation checked."
}

# Function to kill process using a port
kill_process_on_port() {
    local port="$1"
    echo "Checking for processes on port $port..." >&2
    local pid
    pid=$(lsof -ti ":$port" 2>/dev/null)
    if [ -n "$pid" ]; then
        echo "Killing process(es) $pid on port $port..." >&2
        kill -9 $pid 2>/dev/null || true
        sleep 1  # Give time for port to be released
    fi
}

# Function to find an available port with extended range
find_available_port() {
    local base_port="$1"
    local service="$2"
    local max_attempts=10  # Increased attempts
    local port_increment=0
    local current_port

    echo "Finding available port for $service (starting from $base_port)..." >&2
    for attempt in $(seq 1 "$max_attempts"); do
        current_port=$((base_port + port_increment))
        kill_process_on_port "$current_port"
        
        if ! lsof -i ":$current_port" &> /dev/null; then
            # Double-check port availability
            sleep 0.5
            if ! lsof -i ":$current_port" &> /dev/null; then
                echo "Port $current_port is available for $service" >&2
                echo "$current_port"
                return 0
            fi
        fi
        
        echo "Port $current_port unavailable, trying next..." >&2
        port_increment=$((port_increment + 1))
    done

    echo "Failed to find available port for $service after $max_attempts attempts" >&2
    return 1
}

# Function to check and fix Kafka installation
check_kafka() {
    echo "Checking Kafka installation..."
    KAFKA_HOME=$(brew --prefix kafka 2>/dev/null || echo "/opt/homebrew")
    JAVA_HOME=$(brew --prefix openjdk 2>/dev/null || echo "/opt/homebrew/opt/openjdk")
    
    export JAVA_HOME
    export PATH="$JAVA_HOME/bin:$KAFKA_HOME/bin:$PATH"
    
    kill_process_on_port 2181
    
    echo "Starting Zookeeper..."
    nohup zookeeper-server-start "$KAFKA_HOME/etc/kafka/zookeeper.properties" > /tmp/zookeeper.log 2>&1 &
    
    local MAX_RETRIES=10
    local RETRY_COUNT=0
    while ! lsof -i :2181 &> /dev/null && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "Waiting for Zookeeper... (attempt $((RETRY_COUNT + 1)))"
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
    
    [ $RETRY_COUNT -ge $MAX_RETRIES ] && { echo "Zookeeper failed to start"; return 1; }
    
    KAFKA_PORT=$(find_available_port 9092 "Kafka") || { echo "Failed to find Kafka port"; return 1; }
    
    KAFKA_CONFIG="$KAFKA_HOME/etc/kafka/server.properties"
    sed -i.bak "s/^listeners=.*/listeners=PLAINTEXT:\/\/localhost:$KAFKA_PORT/" "$KAFKA_CONFIG" || true
    
    echo "Starting Kafka on port $KAFKA_PORT..."
    nohup kafka-server-start "$KAFKA_CONFIG" > /tmp/kafka.log 2>&1 &
    
    RETRY_COUNT=0
    while ! lsof -i ":$KAFKA_PORT" &> /dev/null && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "Waiting for Kafka... (attempt $((RETRY_COUNT + 1)))"
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
    
    [ $RETRY_COUNT -ge $MAX_RETRIES ] && { echo "Kafka failed to start on port $KAFKA_PORT"; return 1; }
    
    export KAFKA_PORT
    echo "Kafka running on port $KAFKA_PORT."
}

# Function to start Zookeeper and Kafka
start_kafka() {
    echo "Starting Zookeeper and Kafka..."
    check_java && check_kafka || { echo "Failed to start Kafka services"; return 1; }
    echo "Zookeeper and Kafka started successfully."
}

# Function to write initial data to Kafka with retry
write_initial_kafka_data() {
    echo "Writing initial data to Kafka..."
    local MAX_RETRIES=5
    local RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if echo "Initial test message $(date)" | kafka-console-producer \
           --topic test-topic --bootstrap-server localhost:${KAFKA_PORT:-9092} 2>/dev/null; then
            echo "Initial data written successfully."
            return 0
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "Attempt $RETRY_COUNT failed. Retrying..."
        sleep 2
    done
    
    echo "Failed to write initial data after $MAX_RETRIES attempts"
    return 1
}

# Function to create a Kafka topic with retry
create_kafka_topic() {
    echo "Creating Kafka topic 'test-topic'..."
    local MAX_RETRIES=5
    local RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if kafka-topics --list --bootstrap-server localhost:${KAFKA_PORT:-9092} 2>/dev/null | grep -q "^test-topic$"; then
            echo "Topic 'test-topic' exists."
            write_initial_kafka_data
            return 0
        fi
        
        if kafka-topics --create --topic test-topic \
           --bootstrap-server localhost:${KAFKA_PORT:-9092} \
           --partitions 1 --replication-factor 1 2>/dev/null; then
            echo "Topic 'test-topic' created."
            write_initial_kafka_data
            return 0
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "Attempt $RETRY_COUNT failed. Retrying..."
        sleep 2
    done
    
    echo "Failed to create Kafka topic after $MAX_RETRIES attempts"
    return 1
}

# Function to list Kafka topics
list_kafka_topics() {
    echo "Listing Kafka topics..."
    kafka-topics --list --bootstrap-server localhost:${KAFKA_PORT:-9092} 2>/dev/null || \
        echo "Failed to list topics"
}

# Function to start Mosquitto
start_mosquitto() {
    echo "Starting Mosquitto..."
    MQTT_PORT=$(find_available_port 1883 "MQTT") || { echo "Failed to find MQTT port"; return 1; }
    
    cat > /tmp/mosquitto.conf <<EOF
listener $MQTT_PORT
allow_anonymous true
EOF
    
    nohup mosquitto -c /tmp/mosquitto.conf > /tmp/mosquitto.log 2>&1 &
    
    local RETRY_COUNT=0
    local MAX_RETRIES=5
    while ! lsof -i ":$MQTT_PORT" &> /dev/null && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "Waiting for Mosquitto... (attempt $((RETRY_COUNT + 1)))"
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
    
    [ $RETRY_COUNT -ge $MAX_RETRIES ] && { echo "Mosquitto failed to start"; return 1; }
    
    export MQTT_PORT
    echo "Mosquitto started on port $MQTT_PORT"
    
    # Background publishing loop
    (
        while true; do
            random_data=$((RANDOM % 100))
            mosquitto_pub -p "$MQTT_PORT" -t "example/topic" -m "Random data: $random_data" 2>/dev/null || true
            sleep 2
        done
    ) &
}

# Function to start OPC UA server
start_opcua_server() {
    echo "Starting OPC UA server..."
    OPCUA_PORT=$(find_available_port 4841 "OPC UA") || { echo "Failed to find OPC UA port"; return 1; }
    
    sed -i.bak "s/4841/${OPCUA_PORT}/" opcua_server.py 2>/dev/null || true
    sed -i.bak "s/4841/${OPCUA_PORT}/" opcua_client.py 2>/dev/null || true
    
    python3 opcua_server.py > /tmp/opcua_server.log 2>&1 &
    
    local RETRY_COUNT=0
    local MAX_RETRIES=5
    while ! lsof -i ":$OPCUA_PORT" &> /dev/null && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "Waiting for OPC UA... (attempt $((RETRY_COUNT + 1)))"
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
    
    [ $RETRY_COUNT -ge $MAX_RETRIES ] && { echo "OPC UA failed to start"; return 1; }
    
    export OPCUA_PORT
    echo "OPC UA server started on port $OPCUA_PORT."
}

 show_combined_streams() {
    echo "Displaying data streams..."
    OPCUA_FILE="/tmp/opcua_stream.txt"
    KAFKA_FILE="/tmp/kafka_stream.txt"
    MQTT_FILE="/tmp/mqtt_stream.txt"
    HTML_FILE="/tmp/combined.html"
    
    touch "$OPCUA_FILE" "$KAFKA_FILE" "$MQTT_FILE"
    
    start_data_collector() {
        local type="$1"
        local cmd="$2"
        local output_file="$3"
        
        while true; do
            $cmd > "$output_file" 2>&1 &
            local pid=$!
            wait $pid
            [ -f "/tmp/stop_collectors" ] && break
            echo "Restarting $type collector..."
            sleep 1
        done &
    }
    
    start_data_collector "OPC UA" "python3 opcua_client.py" "$OPCUA_FILE"
    start_data_collector "Kafka" "kafka-console-consumer --bootstrap-server localhost:${KAFKA_PORT:-9092} --topic test-topic --from-beginning" "$KAFKA_FILE"
    start_data_collector "MQTT" "mosquitto_sub -p ${MQTT_PORT:-1883} -t example/topic" "$MQTT_FILE"
    
    update_html() {
        cat > "$HTML_FILE.tmp" <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="1">
    <style>
        body { font-family: monospace; margin: 0; padding: 10px; background: #f0f0f0; }
        .container { display: flex; flex-direction: column; height: 95vh; }
        .section { flex: 1; margin: 5px; padding: 10px; border: 1px solid #ccc; border-radius: 5px; background: white; overflow-y: auto; }
        .title { font-weight: bold; margin-bottom: 5px; padding: 5px; background: #e0e0e0; border-radius: 3px; }
        pre { margin: 0; padding: 5px; white-space: pre-wrap; }
    </style>
</head>
<body>
    <div class="container">
        <div class="section"><div class="title">OPC UA Data:</div><pre>$(tail -n 10 "$OPCUA_FILE" 2>/dev/null || echo "Waiting for data...")</pre></div>
        <div class="section"><div class="title">Kafka Stream:</div><pre>$(tail -n 10 "$KAFKA_FILE" 2>/dev/null || echo "Waiting for data...")</pre></div>
        <div class="section"><div class="title">MQTT Stream:</div><pre>$(tail -n 10 "$MQTT_FILE" 2>/dev/null || echo "Waiting for data...")</pre></div>
    </div>
</body>
</html>
EOF
        mv "$HTML_FILE.tmp" "$HTML_FILE" 2>/dev/null
    }
    
    # Initial HTML creation
    update_html
    
    # Open the browser once
    xdg-open "$HTML_FILE" 2>/dev/null || open "$HTML_FILE" 2>/dev/null || \
    zenity --html --url="file://$HTML_FILE" --title="Data Streams" --width=800 --height=900 2>/dev/null || {
        echo "Failed to open GUI. Please manually open $HTML_FILE in a browser."
        return 1
    }
    
    # Update loop runs in background until script is terminated
    (
        while true; do
            [ -f "/tmp/stop_collectors" ] && break
            update_html
            sleep 1
        done
    ) &
    
    # Store the PID of the update loop
    UPDATE_PID=$!
    
    # Wait for manual termination (Ctrl+C) or cleanup signal
    trap 'touch /tmp/stop_collectors; wait $UPDATE_PID; cleanup' EXIT
    wait $UPDATE_PID
}

# Main execution with error handling
main() {
    install_python_packages || echo "Continuing despite package installation issues"
    start_opcua_server || echo "Continuing without OPC UA"
    start_kafka || echo "Continuing without Kafka"
    create_kafka_topic || echo "Continuing without Kafka topic"
    list_kafka_topics || echo "Continuing without topic listing"
    start_mosquitto || echo "Continuing without Mosquitto"
    show_combined_streams || echo "Display failed"
}

main
cleanup