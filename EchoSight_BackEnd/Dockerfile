FROM python:3.10-bullseye

WORKDIR /app

COPY requirements.txt requirements.txt

RUN pip install --upgrade pip

RUN pip install -r requirements.txt

COPY . .

# Make port 8000 available to the world outside this container
EXPOSE 8000

# Define environment variable
# You can set DEBUG to False in a production environment
ENV DEBUG=True

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "EchoSight_BackEnd.wsgi:application"]
