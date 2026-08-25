def format_socket_data(task_type, *datas):
    """Put data in correct format to send to zxtouch tweak

    :param task_type: type of the task
    :param datas: data to be sent
    :return: ZXTouch socket data in correct format
    """
    return (str(task_type) + (";;".join(str(x) for x in datas)) + "\r\n").encode()

def decode_socket_data(data):
    """Decode the socket data

    :param data: socket data
    :return: a tuple. (success?, error message)
    """
    # Guard against an empty payload (connection closed or timed out before
    # the server answered) — indexing data[0] below used to raise IndexError.
    if not data:
        return (False, "no data received: connection closed or timed out")
    data = str(data.decode())

    temp = data.split(";;")
    temp[-1] = temp[-1].replace("\r\n", "")
    if data[0] != "0":
        err_message = "Unknown err because zxtouch doesn't send any error info to python"
        if len(temp) >= 2:
            err_message = temp[1]
        return (False, err_message)
    return (True, temp[1:])





