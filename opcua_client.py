from opcua import Client
import time
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
# Connect to the OPC UA server
client = Client("opc.tcp://localhost:4841")
client.connect()
print("Connected to OPC UA server")

try:
    # Get the root node
    root = client.get_root_node()
    # Access the mock device object
    mock_device = root.get_child(["0:Objects", "2:MockDevice"])
    
    # Continuously read and print the values
    while True:
        temp = mock_device.get_child(["2:Temperature"]).get_value()
        pressure = mock_device.get_child(["2:Pressure"]).get_value()
        flow = mock_device.get_child(["2:FlowRate"]).get_value()
        
        print(f"Temperature: {temp:.2f}, Pressure: {pressure:.2f}, Flow Rate: {flow:.2f}", flush=True)
        time.sleep(1)

except KeyboardInterrupt:
    print("Client stopped.")
finally:
    client.disconnect()
    print("Disconnected from OPC UA server")