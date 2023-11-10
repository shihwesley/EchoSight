with open('requirements.txt', 'r') as file:
    lines = file.readlines()

with open('requirements.txt', 'w') as file:
    for line in lines:
        if 'file:///' in line:
            line = line.split('@')[0] + '\n'
        file.write(line)