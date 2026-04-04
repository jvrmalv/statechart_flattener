import json
import os

def count_stats():
    # Get all json files in the current directory
    files = [f for f in os.listdir('.') if f.endswith('.json')]
    files.sort()

    print(f"{'File':<60} {'States':<10} {'Transitions':<10}")
    print("-" * 80)

    for filename in files:
        try:
            with open(filename, 'r') as f:
                data = json.load(f)
                
            states = data.get('states', [])
            num_states = len(states)
            num_transitions = sum(len(state.get('transitions', [])) for state in states)
            
            print(f"{filename:<60} {num_states:<10} {num_transitions:<10}")
        except Exception as e:
            print(f"Error processing {filename}: {e}")

if __name__ == "__main__":
    count_stats()
