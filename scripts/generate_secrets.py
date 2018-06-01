import random
import string
import os
import subprocess

def random_string_generator(length):
    choices = string.ascii_letters + string.digits + string.punctuation
    while True:
        yield ''.join([ random.choice(choices) for _ in range(length) ])

def generate_ssh_keys(secret_id):
    secret_path = "secrets/{}/key".format(secret_id)
    if os.path.exists(secret_path):
        print("Skipping {} because secret already exists".format(secret_path))
        return

    os.makedirs(os.path.dirname(secret_path), exist_ok=True)
    commandline = [ "ssh-keygen", "-b", "4096", "-N", "", "-f", "{}/key".format(secret_path) ]
    subprocess.check_output(commandline)


def ask_for_string_generator(text):
    while True:
        print("")
        print(text)
        yield input("Please enter (or leave empty to skip):")

def generate_if_not_exists(secret_id, generator):
    secret_path = "secrets/" + secret_id

    if os.path.exists(secret_path):
        print("Skipping {} because secret already exists".format(secret_id))
        return

    value = next(generator)
    os.makedirs(os.path.dirname(secret_path), exist_ok=True)
    with open(secret_path, "w") as text_file:
        text_file.write(value)

if __name__ == "__main__":
    print("This application is used to generate all required secrets for your installation")
    print("It will not overwrite any existing secrets")
    print("")

    rstr_32 = random_string_generator(48)
    generate_if_not_exists("postgresql/nextcloud", rstr_32)

    generate_if_not_exists("initial/user", ask_for_string_generator(
        "Password for the initial user for all services\n"
        + "This user will have administrative rights in all services"
    ))
    generate_if_not_exists("initial/password", ask_for_string_generator("Password for the initial user for all services"))
    generate_ssh_keys("backup")
    generate_if_not_exists("backup/nextcloud", rstr_32)


