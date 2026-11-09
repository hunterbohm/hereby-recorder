import os
import sys

try:
    os.close(os.open('/dev/tty', os.O_RDWR))
    terminal = True
except OSError:
    terminal = False
print(f'controlling_terminal={terminal} stdin_isatty={sys.stdin.isatty()} python={sys.version.split()[0]}', end='')
try:
    import anthropic
    print(f' anthropic={anthropic.__version__}')
except ImportError:
    print(' anthropic=missing')
