/**
 * Dropdown Library with selected items display
 * created for https://github.com/nilabsent/padavan-ng
 *
 * Version: beta
 * Author:  nil
 * Licence: licenced under MIT licence (http://opensource.org/licenses/MIT)
*/

(function($) {
$.fn.dropdownList = function(action, ...args) {
    if (typeof action === 'string' && action.startsWith('on')) {
        const eventName = action.substring(2).toLowerCase();
        return this.each(function() {
            const instance = $(this).data('dropdownInstance');
            if (instance) {
                instance.on(eventName, args[0]);
            }
        });
    }

    if (action === 'instance') {
      return this.data('dropdownInstance');
    }

    $.fn.getSelectedItems = function() {
        const instance = this.data('dropdownInstance');
        return instance ? instance.getSelectedItems() : [];
    };

    $.fn.getAllItems = function() {
        const instance = this.data('dropdownInstance');
        return instance ? instance.getAllItems() : [];
    };

    $.fn.addItem = function(text, checked = false) {
        const instance = this.data('dropdownInstance');
        return instance ? instance.addItem(text, checked) : [];
    };

    return this.each(function() {
        const instance = $(this).data('dropdownInstance');

        if (!instance && typeof action === 'object') {
            const options = action;
            const newInstance = new DropdownList(this, options);
            $(this).data('dropdownInstance', newInstance);
        } else if (instance && typeof action === 'string') {
            if (typeof instance[action] === 'function') {
                instance[action](...args);
            }
        }
    });
}})(jQuery);

class DropdownList {
    constructor(container, options = {}) {
        this.container = typeof container === 'string'
            ? document.getElementById(container)
            : container;

        if (!this.container) {
            console.error('Container element not found');
            return;
        }

        this._events = {};

        this.options = {
            placeholder: 'Add item...',
            allowAdd: true,
            removeAllSpaces: false,
            allowDelete: true,
            multiSelect: true,
            addOnEnter: true,
            allowedItems: '',
            allowedAlert: 'Value not valid',
            displaySelected: true,
            selectedSeparator: ', ',
            ...options
        };

        this.items = this.options.data || [];
        this.init();
    }

    init() {
        this.container.innerHTML = `
            <div class="dropdown-wrapper">
                <div class="dropdown-container">
                    <input type="text" class="dropdown-input" placeholder="${this.options.placeholder}">
                    <svg style="width: 24px;" class="dropdown-indicator" viewBox="0 0 24 24" fill="#555">
                        <path d="M7 10l5 5 5-5z"/>
                    </svg>
                </div>
                <div class="dropdown-list"></div>
            </div>
        `;

        this.dropdownInput = this.container.querySelector('.dropdown-input');
        this.dropdownList = this.container.querySelector('.dropdown-list');
        this.dropdownContainer = this.container.querySelector('.dropdown-container');
        this.indicator = this.container.querySelector('.dropdown-indicator');
        this.dropdownWrapper = this.container.querySelector('.dropdown-wrapper');

        if (!this.options.allowAdd) {
            this.dropdownInput.readOnly = true;
        }

        this.clickedInsideList = false;
        this.isOpen = false;

        this.setupEvents();
        this.updateInputDisplay();
    }

    setupEvents() {
        this.dropdownInput.addEventListener('input', () => {
            this.updateDropdownList(this.dropdownInput.value.toLowerCase());
        });

        this.dropdownInput.addEventListener('focus', () => {
            this.dropdownInput.placeholder = ''; // Очищаем placeholder при фокусе
            this.dropdownInput.value = '';
            this.dropdownInput.classList.remove('display-selected');
            this.updateDropdownList('');
            this.openDropdown();
        });

        this.dropdownInput.addEventListener('blur', () => {
            if (!this.clickedInsideList) {
                this.closeDropdown();
            }
            this.clickedInsideList = false;
            this.updateInputDisplay();
        });

        this.dropdownWrapper.addEventListener('mousedown', (e) => {
            const isScrollbar = e.offsetX > this.dropdownList.clientWidth ||
                               e.offsetY > this.dropdownList.clientHeight;
            if (this.dropdownList.contains(e.target) && !isScrollbar) {
                this.clickedInsideList = true;
            }
        });

        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                this.closeDropdown();
                this.dropdownInput.blur();
                this.updateInputDisplay();
                e.preventDefault();
            }
        });

        this.dropdownInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                if (this.isOpen && this.options.addOnEnter && this.options.allowAdd) {
                    this.handleAddNewItem();
                }
                e.preventDefault();
            }
        });
    }

    updateInputDisplay() {
        if (!this.options.displaySelected || this.isOpen) {
            return;
        }

        const selectedItems = this.getSelectedItems();
        if (selectedItems.length > 0) {
            const selectedText = selectedItems.map(item => item.text).join(this.options.selectedSeparator);
            this.dropdownInput.value = selectedText;
            this.dropdownInput.classList.add('display-selected');
        } else {
            this.dropdownInput.value = '';
            this.dropdownInput.classList.remove('display-selected');
        }
    }

    openDropdown() {
        this.dropdownList.style.display = 'block';
        this.isOpen = true;
        this.trigger('open');
        this.updateIndicator();
        this.dropdownInput.classList.remove('display-selected');
    }

    closeDropdown() {
        this.dropdownInput.placeholder = this.options.placeholder;
        this.dropdownList.style.display = 'none';
        this.isOpen = false;
        this.trigger('close');
        this.updateIndicator();
        this.updateInputDisplay();
    }

    updateIndicator() {
        if (this.isOpen) {
            this.indicator.style.transform = 'translateY(-50%) rotate(180deg)';
        } else {
            this.indicator.style.transform = 'translateY(-50%)';
        }
    }

    handleAddNewItem() {
        const filter = (this.options.removeAllSpaces) ? this.dropdownInput.value.replace(/\s+/g, '') : this.dropdownInput.value.trim();

        if (!filter) return;

        if (this.options.allowedItems) {
            const regex = new RegExp(this.options.allowedItems);
            if (!regex.test(filter)) {
                alert(this.options.allowedAlert);
                return;
            }
        }

        if (this.items.some(item => item.text.toLowerCase() === filter.toLowerCase()))
            return;

        const newId = this.items.length > 0 ? Math.max(...this.items.map(i => i.id)) + 1 : 1;
        const newItem = {
            id: newId,
            text: filter,
            checked: true
        };
        this.items.push(newItem);
        this.dropdownInput.value = '';
        this.updateDropdownList();
        this.updateSelectedItems();
        this.dropdownInput.focus();
    }

    updateDropdownList(filter = '') {
        this.dropdownList.innerHTML = '';

        const filteredItems = this.items.filter(item => 
            item.text.toLowerCase().includes(filter)
        );

        if (filteredItems.length === 0 && !filter) {
            return;
        }

        filteredItems.forEach(item => {
            const itemElement = document.createElement('div');
            itemElement.className = 'dropdown-item';

            const itemContent = document.createElement('div');
            itemContent.className = 'dropdown-item-content';

            const checkbox = document.createElement('input');
            checkbox.type = 'checkbox';
            checkbox.checked = item.checked;
            checkbox.addEventListener('change', (e) => {
                e.stopPropagation();
                item.checked = checkbox.checked;
                this.updateSelectedItems();
                this.dropdownInput.focus();
            });

            const label = document.createElement('span');
            label.textContent = item.text;

            if (this.options.allowDelete) {
                const deleteBtn = document.createElement('span');
                deleteBtn.className = 'delete-item';
                deleteBtn.textContent = '×';
                deleteBtn.title = 'Delete item';
                deleteBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.items = this.items.filter(i => i.id !== item.id);
                    this.updateDropdownList(filter);
                    this.updateSelectedItems();
                    this.dropdownInput.focus();
                });
                itemElement.appendChild(deleteBtn);
            }

            itemContent.appendChild(checkbox);
            itemContent.appendChild(label);
            itemElement.appendChild(itemContent);

            itemElement.addEventListener('click', (e) => {
                if (e.target !== checkbox && (!this.options.allowDelete || e.target.className !== 'delete-item')) {
                    checkbox.checked = !checkbox.checked;
                    item.checked = checkbox.checked;
                    this.updateSelectedItems();
                    this.dropdownInput.focus();
                }
            });

            this.dropdownList.appendChild(itemElement);
        });

        if (this.options.allowAdd && filter && !filteredItems.some(item => item.text.toLowerCase() === filter.toLowerCase())) {
            const addNewElement = document.createElement('div');
            addNewElement.className = 'dropdown-item add-new';

            const addText = document.createElement('span');
            addText.textContent = `<#CTL_add#> "${filter}"`;

            addNewElement.appendChild(addText);

            addNewElement.addEventListener('mousedown', (e) => {
                e.preventDefault();
                this.handleAddNewItem();
            });

            this.dropdownList.appendChild(addNewElement);
        }

        if (this.dropdownList.children.length > 0 && this.isOpen) {
            this.dropdownList.style.display = 'block';
        } else {
            this.dropdownList.style.display = 'none';
        }
    }

    updateSelectedItems() {
        const selectedItems = this.items.filter(item => item.checked);
        this.trigger('change', selectedItems);

        selectedItems.forEach(item => {
            const itemElement = document.createElement('div');
            itemElement.className = 'selected-item';
            itemElement.textContent = item.text;

            const removeBtn = document.createElement('span');
            removeBtn.textContent = '×';
            removeBtn.style.cursor = 'pointer';
            removeBtn.style.marginLeft = '5px';
            removeBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                const itemToUpdate = this.items.find(i => i.id === item.id);
                if (itemToUpdate) {
                    itemToUpdate.checked = false;
                    this.updateSelectedItems();
                    this.updateDropdownList(this.dropdownInput.value.toLowerCase());
                    this.updateInputDisplay();
                }
            });

            itemElement.appendChild(removeBtn);
        });

        this.updateInputDisplay();
    }

    // Public methods
    addItem(text, checked = false) {
        const newId = this.items.length > 0 ? Math.max(...this.items.map(i => i.id)) + 1 : 1;
        const filter = (this.options.removeAllSpaces) ? text.replace(/\s+/g, '') : text.trim();

        if (this.items.some(item => item.text.toLowerCase() === filter.toLowerCase()))
            return;

        if (this.options.allowedItems) {
            const regex = new RegExp(this.options.allowedItems);
            if (!regex.test(filter))
                return;
        }

        const newItem = { id: newId, text: filter, checked };
        this.items.push(newItem);
        this.updateDropdownList();
        this.updateSelectedItems();
        return newItem;
    }

    removeItem(id) {
        this.items = this.items.filter(i => i.id !== id);
        this.updateDropdownList();
        this.updateSelectedItems();
    }

    getSelectedItems() {
        return this.items.filter(item => item.checked);
    }

    getAllItems() {
        return [...this.items];
    }

    clearSelection() {
        this.items.forEach(item => item.checked = false);
        this.updateSelectedItems();
    }

    trigger(eventName, data = null) {
        if (this._events[eventName]) {
            this._events[eventName].forEach(callback => {
                callback.call(this, data);
            });
        }
    }

    on(eventName, callback) {
        if (!this._events[eventName]) {
            this._events[eventName] = [];
        }
        this._events[eventName].push(callback);
        return this;
    }
}
