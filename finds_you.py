import requests
import re

def fetch_books_with_snippets(query, api_key):
    url = "https://www.googleapis.com/books/v1/volumes"
    start_index = 0
    snippets = []

    while True:
        params = {
            'q': query,
            'startIndex': start_index,
            'maxResults': 40,  # Up to 40 is allowed
            'key': api_key
        }
        response = requests.get(url, params=params)
        data = response.json()

        if 'items' not in data:
            break  # Exit loop if no more items are found

        for item in data['items']:
            if 'searchInfo' in item and 'textSnippet' in item['searchInfo']:
                snippets.append(item['searchInfo']['textSnippet'])

        # Check if we need to continue paging
        if 'totalItems' in data and data['totalItems'] > start_index + 40:
            start_index += 40
        else:
            break  # Exit loop if we have fetched all items

    return snippets

def process_snippets(snippets, replacements):
    """
    Processes a list of text snippets by applying multiple regex-based 
    find-and-replace operations.

    This function iterates over each snippet in the provided list, applying 
    each specified replacement operation. Each operation consists of a regex pattern 
    and a replacement string.

    Parameters:
    - snippets (list of str): A list of text snippets to be processed.
    - replacements (list of tuple): A list of tuples where each tuple contains a 
      regex pattern (str) and a replacement string (str). Each pattern is applied 
      to the snippets, replacing matches with the corresponding replacement string.

    Returns:
    - list of str: A list containing the processed snippets after all replacement 
      operations have been applied.
    """
    processed_snippets = []
    
    for snippet in snippets:
        processed_snippet = snippet
        for pattern, replacement in replacements:
            processed_snippet = re.sub(pattern, replacement, processed_snippet)
        if processed_snippet.startswith('finds you'):
            pattern = re.compile(r'[\x00-\x1F\x7F]')
            if not pattern.search(processed_snippet):
                processed_snippets.append(processed_snippet)

    processed_snippets = list(set(processed_snippets)) # Make the list unique

    return processed_snippets


def save_snippets_to_file(snippets, file_name):
    with open(file_name, 'a', encoding='utf-8') as file:
        for snippet in snippets:
            file.write(snippet + '\n')  # Write each snippet in a new paragraph

# Usage example
snippets = fetch_books_with_snippets(query, api_key)

replacements = [
    (r' \. ', '. '),
    (r' , ', ', '),
    (r' ; ', '; '),
    (r' : ', ': '),
    (r'^... ', ''),
    (r'^(.*)finds you ', 'finds you '),
    (r'[\.!\?](.*)', '.'),
    (r'<.*?>', ''),
    (r'&#39;', '’'),
    (r' - ', '-'),
    (r'([A-Za-z])- ', '\1'),
    (r'&nbsp;', ''),
    (r'&quot;', '"')
]
processed_snippets = process_snippets(snippets, replacements)

save_snippets_to_file(processed_snippets, 'finds_you.txt')
print("Processed snippets successfully saved to finds_you.txt.")
