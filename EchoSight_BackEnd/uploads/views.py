import base64
import io
import os
import time

#import cv2  # We're using OpenCV to read video
import requests
from django.http import StreamingHttpResponse
from IPython.display import Audio, Image, display
from openai import OpenAI
from PIL import \
    Image as PilImage  # Make sure to install Pillow with: pip install Pillow
from rest_framework import status
from rest_framework.parsers import FormParser, MultiPartParser
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Image
from .serializers import ImageSerializer

# def get_secret():

#     secret_name = "OPENAI_API_KEY"
#     region_name = "us-east-1"

#     # Create a Secrets Manager client
#     session = boto3.session.Session()
#     client = session.client(
#         service_name='secretsmanager',
#         region_name=region_name
#     )

#     try:
#         get_secret_value_response = client.get_secret_value(
#             SecretId=secret_name
#         )
#     except ClientError as e:
#         # For a list of exceptions thrown, see
#         # https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html
#         raise e

#     # Decrypts secret using the associated KMS key.
#     secret = get_secret_value_response['SecretString']

openai_api_key = os.environ.get('OPENAI_API_KEY')
client = OpenAI(api_key= openai_api_key)

def encode_image(image_file, size):
    # Open the image file with PIL
    img = PilImage.open(image_file)

    # Calculate the ratio to resize the image while maintaining aspect ratio
    width, height = img.size
    ratio = max(size/width, size/height)
    new_size = (int(width*ratio), int(height*ratio))

    # Resize the image
    img = img.resize(new_size, PilImage.LANCZOS)

    # Save the resized image to a BytesIO object
    buffer = io.BytesIO()
    img.save(buffer, format='JPEG')

    # Get the contents of the BytesIO object
    image_data = buffer.getvalue()

    # Encode the image data
    base64_image = base64.b64encode(image_data).decode()

    return base64_image

def get_audio_stream(description_text):
    try:
        print('world')
        response = client.audio.speech.create(
            model="tts-1",
            voice="alloy",
            input=description_text,
        )
        # Ensure response is successful and contains audio data
        if response is not None and hasattr(response, 'content'):
            # Return the audio content directly
            return response.content
        else:
            print("No audio content in the response")
            return None
    except Exception as e:
        print(f"Error generating audio: {e}")
        return None



class ImageUploadView(APIView):
    parser_classes = (MultiPartParser, FormParser)

    def post(self, request, *args, **kwargs):
        print('hello')
        data = {'image': request.data.get('photo')}
        # Create a new dictionary with 'image' key
        image_file = data.get("image")

        base64_image = encode_image(image_file, 800)



        if not image_file:
            return Response({"message": "No image file provided"},
                            status=status.HTTP_400_BAD_REQUEST)

        # Process the image file
        #image = PilImage.open(image_file)

        # Perform your image processing here (e.g., resizing, cropping, etc.)
        PROMPT_MESSAGES = [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "What’s in this image?"
                    },
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:image/jpeg;base64,{base64_image}"
                        }
                    }
                ],
            },
        ]
        params = {
            "model": "gpt-4-vision-preview",
            "messages": PROMPT_MESSAGES,
            "max_tokens": 300,
        }

        result = client.chat.completions.create(**params)
        #print(result.choices[0].message.content)
        description_text = result.choices[0].message.content
        print(description_text)
        # Convert the description text to audio
        audio_stream = get_audio_stream(description_text)
        # Convert audio_stream to a format that can be sent in the response
        #audio_content = audio_stream.read()  # This depends on how your audio stream is structured
        # Encode the audio content to base64 to send as part of the JSON response
        encoded_audio = base64.b64encode(audio_stream).decode('utf-8')
        return Response({"message": "Description generated", "audio": encoded_audio},
                        status=status.HTTP_200_OK)
