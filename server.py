from flask import Flask, request, jsonify
from flask_cors import CORS
import logging
import os
import json
from datetime import datetime
from flask import send_from_directory


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)  # Enable CORS for all routes

# Create uploads directory if it doesn't exist
UPLOAD_DIR = "uploads"
if not os.path.exists(UPLOAD_DIR):
    os.makedirs(UPLOAD_DIR)

def save_to_txt_file(device_data, video_filename, video_size, timestamp):
    """Save device data to a text file"""
    try:
        # Create filename based on timestamp and device ID
        txt_filename = f"device_data_{device_data['device_id']}_{timestamp}.txt"
        txt_filepath = os.path.join(UPLOAD_DIR, txt_filename)
        
        with open(txt_filepath, 'w', encoding='utf-8') as f:
            f.write("=== DEVICE VERIFICATION DATA ===\n")
            f.write(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"Received At: {datetime.now().isoformat()}\n")
            f.write("\n--- DEVICE INFORMATION ---\n")
            f.write(f"Device ID: {device_data['device_id']}\n")
            f.write(f"Is Compromised: {device_data['is_compromised']}\n")
            f.write(f"Platform: {device_data.get('platform', 'unknown')}\n")
            f.write(f"IP Address: {device_data['ip_address']}\n")
            
            f.write("\n--- LOCATION DATA ---\n")
            f.write(f"Latitude: {device_data['gps_location']['latitude']}\n")
            f.write(f"Longitude: {device_data['gps_location']['longitude']}\n")
            
            f.write("\n--- VIDEO INFORMATION ---\n")
            f.write(f"Video Filename: {video_filename}\n")
            f.write(f"Video Size: {video_size} bytes\n")
            f.write(f"Video Saved As: mobile_liveness_{device_data['device_id']}_{timestamp}.mp4\n")
            
            f.write("\n--- RAW JSON DATA ---\n")
            f.write(json.dumps(device_data, indent=2))
        
        logger.info(f"📄 Data saved to: {txt_filepath}")
        return txt_filepath
        
    except Exception as e:
        logger.error(f"❌ Error saving text file: {str(e)}")
        return None

@app.route('/verify', methods=['POST', 'OPTIONS'])
def verify_endpoint():
    if request.method == 'OPTIONS':
        return '', 200
        
    try:
        logger.info("📱 Received verification request from mobile device")
        
        # Check if request is multipart/form-data
        if not request.content_type or 'multipart/form-data' not in request.content_type:
            logger.error("❌ Invalid content type")
            return jsonify({"error": "Content type must be multipart/form-data"}), 400
        
        # Get the JSON data part
        if 'data' not in request.form:
            logger.error("❌ Missing 'data' part")
            return jsonify({"error": "Missing 'data' part"}), 400
        
        # Parse JSON data
        try:
            json_data = request.form['data']
            device_data = json.loads(json_data)
            logger.info(f"✅ Parsed JSON data: {json.dumps(device_data, indent=2)}")
        except json.JSONDecodeError as e:
            logger.error(f"❌ JSON decode error: {e}")
            return jsonify({"error": "Invalid JSON in 'data' part"}), 400
        
        # Check required fields
        required_fields = ['device_id', 'is_compromised', 'gps_location', 'ip_address']
        for field in required_fields:
            if field not in device_data:
                logger.error(f"❌ Missing required field: {field}")
                return jsonify({"error": f"Missing required field: {field}"}), 400
        
        # Get the video file part
        if 'liveness_video' not in request.files:
            logger.error("❌ Missing 'liveness_video' file")
            return jsonify({"error": "Missing 'liveness_video' file"}), 400
        
        video_file = request.files['liveness_video']
        
        # Check if video file was selected
        if video_file.filename == '':
            logger.error("❌ No video file selected")
            return jsonify({"error": "No video file selected"}), 400
        
        # Log successful receipt
        logger.info("✅ Successfully received verification request:")
        logger.info(f"   📱 Device ID: {device_data['device_id']}")
        logger.info(f"   🚨 Is Compromised: {device_data['is_compromised']}")
        logger.info(f"   📍 GPS Location: {device_data['gps_location']}")
        logger.info(f"   🌐 IP Address: {device_data['ip_address']}")
        logger.info(f"   🎥 Video Filename: {video_file.filename}")
        logger.info(f"   📹 Video Content Type: {video_file.content_type}")
        
        # Read video file size
        video_data = video_file.read()
        video_size = len(video_data)
        logger.info(f"   💾 Video Size: {video_size} bytes")
        
        # Reset file pointer
        video_file.stream.seek(0)
        
        # Generate timestamp for filenames
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        # Save the video file
        video_filename = f"mobile_liveness_{device_data['device_id']}_{timestamp}.mp4"
        video_filepath = os.path.join(UPLOAD_DIR, video_filename)
        video_file.save(video_filepath)
        logger.info(f"   💿 Video saved to: {video_filepath}")
        
        # Save data to text file
        txt_filepath = save_to_txt_file(device_data, video_file.filename, video_size, timestamp)
        
        response_data = {
            "status": "received_ok",
            "message": "Successfully received both JSON data and video file from mobile",
            "received_at": datetime.now().isoformat(),
            "device_id": device_data['device_id'],
            "video_size": video_size,
            "video_saved_as": video_filename,
            "data_saved_as": os.path.basename(txt_filepath) if txt_filepath else "failed"
        }
        
        logger.info("✅ Request processed successfully")
        return jsonify(response_data), 200
        
    except Exception as e:
        logger.error(f"❌ Error processing request: {str(e)}")
        return jsonify({"error": "Internal server error", "details": str(e)}), 500

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({
        "status": "server_is_running", 
        "timestamp": datetime.now().isoformat()
    }), 200

@app.route('/files', methods=['GET'])
def list_files():
    """Endpoint to list all uploaded files"""
    try:
        files = []
        for filename in os.listdir(UPLOAD_DIR):
            filepath = os.path.join(UPLOAD_DIR, filename)
            if os.path.isfile(filepath):
                files.append({
                    "name": filename,
                    "size": os.path.getsize(filepath),
                    "modified": datetime.fromtimestamp(os.path.getmtime(filepath)).isoformat()
                })
        
        return jsonify({
            "files": files,
            "count": len(files)
        }), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500
@app.route('/download/<filename>', methods=['GET'])
def download_file(filename):
    try:
        return send_from_directory(UPLOAD_DIR, filename, as_attachment=False)
    except Exception as e:
        return jsonify({"error": str(e)}), 404


@app.route('/', methods=['GET'])
def home():
    return jsonify({
        "message": "Liveness Verification Server",
        "endpoints": {
            "POST /verify": "Receive video and JSON data",
            "GET /health": "Server health check",
            "GET /files": "List uploaded files"
        }
    }), 200

if __name__ == '__main__':
    pass
