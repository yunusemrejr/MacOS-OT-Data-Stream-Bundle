import time
import random
from opcua import Server
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
# Initialize the OPC UA server
server = Server()
server.set_endpoint("opc.tcp://0.0.0.0:4842")  # Default OPC UA port
server.set_server_name("Mock OPC UA Server")

# Register a namespace for our tags
uri = "http://example.com/mockopcua"
idx = server.register_namespace(uri)

# Get the objects node to add our custom tags
objects = server.get_objects_node()

# Create some made-up tags under a custom object
mock_device = objects.add_object(idx, "MockDevice")
temp_tag = mock_device.add_variable(idx, "Temperature", 25.0)
pressure_tag = mock_device.add_variable(idx, "Pressure", 1000.0)
flow_tag = mock_device.add_variable(idx, "FlowRate", 10.0)

# Make the tags writable (optional, for testing with clients)
temp_tag.set_writable()
pressure_tag.set_writable()
flow_tag.set_writable()

# Start the server
server.start()
print("Mock OPC UA Server started at opc.tcp://localhost:4842", flush=True)

try:
    # Simulate random value updates
    while True:
        # Generate random values
        temp_value = random.uniform(20.0, 30.0)    # Temperature between 20 and 30
        pressure_value = random.uniform(950.0, 1050.0)  # Pressure between 950 and 1050
        flow_value = random.uniform(5.0, 15.0)     # Flow rate between 5 and 15

        # Update tag values
        temp_tag.set_value(temp_value)
        pressure_tag.set_value(pressure_value)
        flow_tag.set_value(flow_value)

        print(f"Temperature: {temp_value:.2f}, Pressure: {pressure_value:.2f}, Flow Rate: {flow_value:.2f}", flush=True)
        
        # Wait for a short interval before next update
        time.sleep(1)

except KeyboardInterrupt:
    print("Shutting down server...", flush=True)
finally:
    server.stop()
    print("Server stopped.", flush=True)